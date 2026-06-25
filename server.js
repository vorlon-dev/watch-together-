const express = require('express');
const http = require('http');
const { Server } = require('socket.io');

const app = express();
const server = http.createServer(app);
const io = new Server(server);

app.use(express.static('public'));

// roomData: { videoId, currentTime }
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

      // Send current video ID AND time if available
      const data = roomData[roomId];
      if (data) {
        socket.emit('current-video', data);
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

    // Update stored video & time
    if (!roomData[roomId]) roomData[roomId] = {};
    if (command.action === 'load') {
      roomData[roomId].videoId = command.videoId;
      roomData[roomId].currentTime = 0;
    } else if (command.action === 'play' || command.action === 'pause' || command.action === 'seek') {
      if (command.currentTime !== undefined) {
        roomData[roomId].currentTime = command.currentTime;
      } else if (command.time !== undefined) {
        roomData[roomId].currentTime = command.time;
      }
    } else if (command.action === 'sync') {
      roomData[roomId].currentTime = command.time;
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