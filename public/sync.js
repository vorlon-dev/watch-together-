// public/sync.js
(() => {
  const player = document.getElementById('player-frame');
  let currentTime = 0;
  let ready = false;
  let pendingCommand = null;
  let isHost = false;  // will be set from outside

  // Expose for Dart / external use
  window.__playerReady = false;
  window.__currentTime = 0;

  // Keep track of current time every 100ms
  setInterval(() => {
    if (player && player.contentWindow) {
      player.contentWindow.postMessage(
        '{"event":"command","func":"getCurrentTime","args":""}', '*'
      );
    }
  }, 100);

  // Listen to messages from YouTube
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
        if (pendingCommand) {
          executeCommand(pendingCommand);
          pendingCommand = null;
        }
      } else if (data.event === 'onStateChange' && isHost) {
        // Notify Flutter / web client about state change
        if (window.FlutterBridge) {
          FlutterBridge.postMessage(JSON.stringify({
            event: 'stateChange',
            state: data.info,
            time: currentTime
          }));
        }
        if (window.onPlayerStateChange) {
          window.onPlayerStateChange(data.info, currentTime);
        }
      }
    } catch (e) {}
  });

  // Commands that can be called from outside
  window.loadVideo = (videoId) => {
    const origin = window.location.origin;
    player.src = `https://www.youtube.com/embed/${videoId}?enablejsapi=1&origin=${encodeURIComponent(origin)}&controls=1&playsinline=1`;
    if (isHost) {
      // Auto-play after 1.5s
      setTimeout(() => sendCommand('playVideo'), 1500);
    }
  };

  window.playVideo = () => sendCommand('playVideo');
  window.pauseVideo = () => sendCommand('pauseVideo');
  window.seekTo = (seconds) => sendCommand('seekTo', seconds);

  function sendCommand(func, args) {
    if (!player || !player.contentWindow) return;
    const cmd = { event: 'command', func, args: args !== undefined ? [args] : [] };
    player.contentWindow.postMessage(JSON.stringify(cmd), '*');
  }

  function executeCommand(cmd) {
    switch (cmd.action) {
      case 'play':
        window.seekTo(cmd.currentTime);
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
        // Only correct if difference > 0.5s
        if (Math.abs(currentTime - cmd.time) > 0.5) {
          window.seekTo(cmd.time);
        }
        break;
    }
  }

  // This will be called by host's control logic
  window.sendHostCommand = (action) => {
    let cmd = { action };
    if (action === 'play') cmd.currentTime = currentTime;
    else if (action === 'pause') cmd.time = currentTime;
    return cmd;
  };

  // For viewer: apply incoming commands
  window.applySyncCommand = (cmd) => {
    if (!ready) {
      pendingCommand = cmd;
      return;
    }
    executeCommand(cmd);
  };

  // Set role from outside
  window.setHost = (flag) => { isHost = flag; };

  // Force ready after 4s (fallback)
  setTimeout(() => {
    if (!ready) {
      window.__playerReady = true;
      ready = true;
      document.getElementById('loading-msg').style.display = 'none';
    }
  }, 4000);
})();