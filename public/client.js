// public/client.js

let socket;
let player;        // the iframe element
let isHost = false;
let roomId = null;
let videoId = null;
let playerReady = false;
let pendingCommand = null;   // store the last play/pause/seek command

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

// ---------- When joining a room that already has a video loaded ----------
socket.on('current-video', (videoIdFromServer) => {
  console.log('✅ Received current-video:', videoIdFromServer);
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
    statusText.textContent = 'You are the host. Load a video to start.';
  } else {
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
        console.log('🎬 Player ready');
        // Apply any pending command (play/pause/seek)
        if (pendingCommand) {
          executeCommand(pendingCommand);
          pendingCommand = null;
        }
        statusText.textContent = 'Player ready.';
      } else if (data.event === 'onStateChange') {
        if (isHost) {
          if (data.info === 1) { // playing
            // Send current time to viewers for sync
            requestCurrentTime((currentTime) => {
              socket.emit('host-command', [roomId, { action: 'play', currentTime }]);
            });
          } else if (data.info === 2) { // paused
            socket.emit('host-command', [roomId, { action: 'pause' }]);
          }
        }
      } else if (data.event === 'infoDelivery' && data.info && data.info.currentTime !== undefined) {
        // Response to getCurrentTime request
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
  console.log('📺 Loading video:', videoId);
  player.src = src;

  // If host, auto-play after a short delay to let player initialise
  if (isHost) {
    setTimeout(() => {
      playVideo();
      statusText.textContent = 'Playing...';
    }, 1000);  // wait 1 second for player to be ready
  } else {
    // Viewer: we'll wait for the 'play' command from host, or auto-play after 3 seconds as fallback
    setTimeout(() => {
      if (!playerReady && !pendingCommand) {
        playVideo();  // fallback auto-play
      }
    }, 3000);
  }
}

// Helper: request current time from YouTube player
function requestCurrentTime(callback) {
  if (player && player.contentWindow) {
    player.contentWindow.postMessage('{"event":"command","func":"getCurrentTime","args":""}', '*');
    window._requestedTimeCallback = callback;
    // fallback if no response
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

function executeCommand(cmd) {
  switch (cmd.action) {
    case 'play':
      playVideo();
      break;
    case 'pause':
      pauseVideo();
      break;
    case 'seek':
      seekTo(cmd.time);
      break;
  }
}

// ---------- Host: load a video ----------
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

// ---------- Viewer sync: handle commands from host ----------
socket.on('sync-command', (command) => {
  console.log('📨 Received sync command:', command);
  if (!player) return;

  // If player isn't ready yet, store command to apply later
  if (!playerReady) {
    pendingCommand = command;
    return;
  }

  switch (command.action) {
    case 'load':
      videoId = command.videoId;
      loadVideoDirect(command.videoId);
      statusText.textContent = 'Video loaded. Syncing...';
      break;
    case 'play':
      // Seek to host's current time, then play
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

// ---------- Host seek detection (mouseup on player) ----------
document.addEventListener('mouseup', (e) => {
  if (!isHost || !player || !playerReady || !roomId) return;
  const playerElement = document.getElementById('youtube-player');
  if (playerElement && playerElement.contains(e.target)) {
    setTimeout(() => {
      requestCurrentTime((currentTime) => {
        socket.emit('host-command', [roomId, {
          action: 'seek',
          time: currentTime,
          state: 'playing'   // we assume playing while seeking
        }]);
      });
    }, 100);
  }
});

// ---------- Periodic sync (host sends time every 10s) ----------
setInterval(() => {
  if (isHost && player && playerReady && roomId) {
    requestCurrentTime((currentTime) => {
      socket.emit('host-command', [roomId, { action: 'sync', time: currentTime }]);
    });
  }
}, 10000);