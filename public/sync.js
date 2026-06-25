// public/sync.js
(() => {
  const player = document.getElementById('player-frame');
  let currentTime = 0;
  let ready = false;
  let pendingCmd = null;
  let isHost = false;

  window.__playerReady = false;
  window.__currentTime = 0;

  // ----- poll current time every 100ms -----
  function pollTime() {
    if (player && player.contentWindow) {
      player.contentWindow.postMessage(
        '{"event":"command","func":"getCurrentTime","args":""}', '*'
      );
    }
  }
  setInterval(pollTime, 100);

  // ----- message listener -----
  window.addEventListener('message', (event) => {
    if (event.origin !== 'https://www.youtube.com') return;
    try {
      const data = JSON.parse(event.data);
      if (data.event === 'infoDelivery' && data.info && typeof data.info.currentTime === 'number') {
        currentTime = data.info.currentTime;
        window.__currentTime = currentTime;
      } else if (data.event === 'onReady') {
        ready = true;
        window.__playerReady = true;
        document.getElementById('loading-msg').style.display = 'none';
        if (pendingCmd) {
          executeCommand(pendingCmd);
          pendingCmd = null;
        }
        if (isHost) {
          setTimeout(() => sendCommand('playVideo'), 800);
        }
        // Notify Flutter
        if (window.FlutterBridge) {
          FlutterBridge.postMessage('playerReady');
        }
      } else if (data.event === 'onStateChange' && isHost) {
        if (window.FlutterBridge) {
          FlutterBridge.postMessage(JSON.stringify({
            event: 'stateChange',
            state: data.info,
            time: currentTime
          }));
        }
      }
    } catch (e) {}
  });

  // ----- helper to send commands to YouTube -----
  function sendCommand(func, args) {
    if (!player || !player.contentWindow) return;
    const cmd = { event: 'command', func: func, args: args !== undefined ? [args] : [] };
    player.contentWindow.postMessage(JSON.stringify(cmd), '*');
  }

  // ----- public functions -----
  window.loadVideo = (videoId) => {
    const origin = window.location.origin;
    player.src = `https://www.youtube.com/embed/${videoId}?enablejsapi=1&origin=${encodeURIComponent(origin)}&controls=1&playsinline=1`;
  };

  window.playVideo = () => sendCommand('playVideo');
  window.pauseVideo = () => sendCommand('pauseVideo');
  window.seekTo = (seconds) => sendCommand('seekTo', seconds);

  // execute a sync command
  function executeCommand(cmd) {
    switch (cmd.action) {
      case 'load':
        window.loadVideo(cmd.videoId);
        break;
      case 'play':
        window.seekTo(cmd.currentTime || 0);
        window.playVideo();
        break;
      case 'pause':
        window.seekTo(cmd.time || currentTime);
        window.pauseVideo();
        break;
      case 'seek':
        window.seekTo(cmd.time);
        break;
      case 'sync':
        if (Math.abs(currentTime - cmd.time) > 0.5) {
          window.seekTo(cmd.time);
        }
        break;
    }
  }

  // Called from Dart (viewer) or web client
  window.applySyncCommand = (cmd) => {
    if (!ready) {
      pendingCmd = cmd;
      return;
    }
    executeCommand(cmd);
  };

  // Called when a current video arrives (with time)
  window.setCurrentVideo = (videoId, videoTime) => {
    window.loadVideo(videoId);
    // After loading, seek to the stored time once ready
    const seekInterval = setInterval(() => {
      if (ready) {
        clearInterval(seekInterval);
        window.seekTo(videoTime);
      }
    }, 200);
  };

  window.setHost = (flag) => { isHost = flag; };

  // Force ready after 5s (fallback)
  setTimeout(() => {
    if (!ready) {
      ready = true;
      window.__playerReady = true;
      document.getElementById('loading-msg').style.display = 'none';
      if (window.FlutterBridge) {
        FlutterBridge.postMessage('playerReady');
      }
    }
  }, 5000);
})();