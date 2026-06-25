const express = require('express');
const http = require('http');
const { Server } = require('socket.io');

const app = express();
const server = http.createServer(app);
const io = new Server(server);

app.use(express.static('public'));

// roomData: { videoId, currentTime, playing }
const roomData = {};

io.on('connection', (socket) => {
  console.log('a user connected:', socket.id);

  socket.on('create-room', (roomId) => {
    socket.join(roomId);
    socket.emit('room-created', roomId);
    console.log(`Room ${roomId} created by ${socket.id}`);
  });

  socket.on('join-room', (roomId) => {
    const room = io.sockets.adapter.rooms.get(roomId);
    if (room && room.size > 0) {
      socket.join(roomId);
      socket.emit('room-joined', roomId);

      // Send current video ID, time, and play state
      const data = roomData[roomId];
      if (data) {
        socket.emit('current-video', {
          videoId: data.videoId,
          currentTime: data.currentTime,
          playing: data.playing   // <-- NEW
        });
      }
      console.log(`${socket.id} joined room ${roomId}`);
    } else {
      socket.emit('room-error', 'Room does not exist.');
    }
  });

  // Host sends a sync command
  socket.on('host-command', (data) => {
    const roomId = data[0];
    const command = data[1];

    // Keep room data up to date
    if (!roomData[roomId]) roomData[roomId] = {};
    if (command.action === 'load') {
      roomData[roomId].videoId = command.videoId;
      roomData[roomId].currentTime = 0;
      roomData[roomId].playing = false;
    } else if (command.action === 'play') {
      roomData[roomId].playing = true;
      if (command.currentTime !== undefined) {
        roomData[roomId].currentTime = command.currentTime;
      }
    } else if (command.action === 'pause') {
      roomData[roomId].playing = false;
      if (command.time !== undefined) {
        roomData[roomId].currentTime = command.time;
      }
    } else if (command.action === 'seek' || command.action === 'sync') {
      if (command.time !== undefined) {
        roomData[roomId].currentTime = command.time;
      }
    }

    // Broadcast to all other clients in the room
    socket.to(roomId).emit('sync-command', command);
  });

  socket.on('disconnect', () => {
    console.log('user disconnected:', socket.id);
  });
});

const PORT = 3000;
server.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});