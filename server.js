const express = require('express');
const http = require('http');
const { Server } = require('socket.io');

const app = express();
const server = http.createServer(app);
const io = new Server(server);

app.use(express.static('public'));

// Store current video for each room
const roomVideos = {};

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
      socket.to(roomId).emit('user-joined', socket.id);

      // Send the current video ID if one is loaded
      if (roomVideos[roomId]) {
        socket.emit('current-video', roomVideos[roomId]);
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

    // Save video ID when host loads a new video
    if (command.action === 'load') {
      roomVideos[roomId] = command.videoId;
    }

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