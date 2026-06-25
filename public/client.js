// public/client.js

let socket;
let player;
let isHost = false;
let roomId = null;
let videoId = null;
let playerReady = false;

socket = io();

const roomControls = document.getElementById('room-controls');
const playerArea = document.getElementById('player-area');
const createRoomBtn = document.getElementById('create-room-btn');
const joinRoomBtn = document.getElementById('join-room-btn');
const roomIdInput = document.getElementById('room-id-input');
const roomIdDisplay = document.getElementById('room-id-display');
const youtubeUrlInput = document.getElementById('youtube-url');
const loadVideoBtn = document.getElementById('load-video-btn');
const statusText = document.getElementById('status');

// ---------- Custom control buttons (only for host) ----------
const hostControls = document.createElement('div');
hostControls.id = 'host-controls';
hostControls.style.display = 'none';
hostControls.innerHTML = `
  <button id="btn-play" style="margin:5px; padding:10px 20px; font-size:16px;">▶ Play</button>
  <button id="btn-pause" style="margin:5px; padding:10px 20px; font-size:16px;">⏸️ Pause</button>
`;
document.getElementById('app').appendChild(hostControls);

const btnPlay = document.getElementById('btn-play');
const btnPause = document.getElementById('btn-pause');

// ---------- Room handling ----------
createRoomBtn.addEventListener('click', () => {
  roomId = Math.random().toString(36).substring(2, 8);
  socket.emit('create-room', roomId);
});

joinRoomBtn.addEventListener('click', () => {
  const id = roomIdInput.value.trim();
  if (id) {
    roomId = id;
    socket.emit('join-room', roomId);
  }
});

socket.on('room-created', (id) => {
  isHost = true;
  enterRoom(id);
});

socket.on('room-joined', (id) => {
  isHost = false;
  enterRoom(id);
});

socket.on('room-error', (msg) => {
  alert(msg);
});

socket.on('current-video', (videoIdFromServer) => {
  videoId = videoIdFromServer;
  loadVideoDirect(videoId);
  statusText.textContent = 'Video loaded. Syncing...';
});

function enterRoom(id) {
  roomControls.style.display = 'none';
  playerArea.style.display = 'block';
  roomIdDisplay.textContent = id;

  if (isHost) {
    youtubeUrlInput.disabled = false;
    loadVideoBtn.disabled = false;
    hostControls.style.display = 'block';
    statusText.textContent = 'You are the host. Load a video to start.';
  } else {
    hostControls.style.display = 'none';
    statusText.textContent = 'Joining room...';
  }

  initPlayer();
}

// ---------- Direct iframe player ----------
function initPlayer() {
  const container = document.getElementById('youtube-player');
  container.innerHTML = '';

  const iframe = document.createElement('iframe');
  iframe.id = 'player-frame';
  iframe.setAttribute('allowfullscreen', '');
  iframe.style.width = '100%';
  iframe.style.height = '100%';
  iframe.style.border = 'none';
  container.appendChild(iframe);
  player = iframe;

  window.addEventListener('message', (event) => {
    if (event.origin !== 'https://www.youtube.com') return;
    try {
      const data = JSON.parse(event.data);
      if (data.event === 'onReady') {
        playerReady = true;
        statusText.textContent = 'Player ready.';
      } else if (data.event === 'onStateChange') {
        if (isHost) {
          if (data.info === 1) { // playing
            requestCurrentTime((currentTime) => {
              socket.emit('host-command', [roomId, { action: 'play', currentTime }]);
            });
          } else if (data.info === 2) { // paused
            socket.emit('host-command', [roomId, { action: 'pause' }]);
          }
        }
      } else if (data.event === 'infoDelivery' && data.info && data.info.currentTime !== undefined) {
        if (window._requestedTimeCallback) {
          window._requestedTimeCallback(data.info.currentTime);
          window._requestedTimeCallback = null;
        }
      }
    } catch (e) {}
  });

  player.src = 'about:blank';
}

function loadVideoDirect(videoId) {
  if (!player) return;
  const origin = window.location.origin;
  const src = `https://www.youtube.com/embed/${videoId}?enablejsapi=1&origin=${encodeURIComponent(origin)}&controls=1&playsinline=1`;
  player.src = src;

  if (isHost) {
    setTimeout(() => {
      playVideo();
      statusText.textContent = 'Playing...';
    }, 1000);
  } else {
    setTimeout(() => {
      if (!playerReady && !pendingCommand) {
        playVideo();
      }
    }, 3000);
  }
}

function requestCurrentTime(callback) {
  if (player && player.contentWindow) {
    player.contentWindow.postMessage('{"event":"command","func":"getCurrentTime","args":""}', '*');
    window._requestedTimeCallback = callback;
    setTimeout(() => {
      if (window._requestedTimeCallback) {
        window._requestedTimeCallback(0);
        window._requestedTimeCallback = null;
      }
    }, 500);
  }
}

function playVideo() {
  if (player && player.contentWindow) {
    player.contentWindow.postMessage('{"event":"command","func":"playVideo","args":""}', '*');
  }
}

function pauseVideo() {
  if (player && player.contentWindow) {
    player.contentWindow.postMessage('{"event":"command","func":"pauseVideo","args":""}', '*');
  }
}

function seekTo(seconds) {
  if (player && player.contentWindow) {
    player.contentWindow.postMessage(`{"event":"command","func":"seekTo","args":${seconds}}`, '*');
  }
}

// ---------- Custom button actions ----------
btnPlay.addEventListener('click', () => {
  if (!isHost || !player || !playerReady) return;
  requestCurrentTime((currentTime) => {
    socket.emit('host-command', [roomId, { action: 'play', currentTime }]);
    playVideo();
  });
});

btnPause.addEventListener('click', () => {
  if (!isHost || !player || !playerReady) return;
  requestCurrentTime((currentTime) => {
    socket.emit('host-command', [roomId, { action: 'pause', time: currentTime }]);
    pauseVideo();
  });
});

// ---------- Host load ----------
loadVideoBtn.addEventListener('click', () => {
  const url = youtubeUrlInput.value.trim();
  videoId = extractVideoId(url);
  if (!videoId) {
    alert('Invalid YouTube URL');
    return;
  }
  loadVideoDirect(videoId);
  socket.emit('host-command', [roomId, { action: 'load', videoId: videoId }]);
});

function extractVideoId(url) {
  const regex = /(?:https?:\/\/)?(?:www\.)?(?:youtube\.com\/(?:watch\?v=|embed\/|shorts\/)|youtu\.be\/)([a-zA-Z0-9_-]{11})/;
  const match = url.match(regex);
  return match ? match[1] : null;
}

// ---------- Viewer sync ----------
socket.on('sync-command', (command) => {
  if (!player) return;

  if (!playerReady) {
    pendingCommand = command;
    return;
  }

  switch (command.action) {
    case 'load':
      videoId = command.videoId;
      loadVideoDirect(command.videoId);
      break;
    case 'play':
      seekTo(command.currentTime);
      playVideo();
      break;
    case 'pause':
      pauseVideo();
      break;
    case 'seek':
      seekTo(command.time);
      break;
    case 'sync':
      seekTo(command.time);
      break;
  }
});

// ---------- Host seek detection ----------
document.addEventListener('mouseup', (e) => {
  if (!isHost || !player || !playerReady || !roomId) return;
  const playerElement = document.getElementById('youtube-player');
  if (playerElement && playerElement.contains(e.target)) {
    setTimeout(() => {
      requestCurrentTime((currentTime) => {
        socket.emit('host-command', [roomId, {
          action: 'seek',
          time: currentTime,
          state: 'playing'
        }]);
      });
    }, 100);
  }
});

// ---------- Periodic sync ----------
setInterval(() => {
  if (isHost && player && playerReady && roomId) {
    requestCurrentTime((currentTime) => {
      socket.emit('host-command', [roomId, { action: 'sync', time: currentTime }]);
    });
  }
}, 5000);