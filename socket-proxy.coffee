# module imports
_        = require 'underscore'
net      = require 'net'
fs       = require 'fs'
http     = require 'https'
express  = require 'express'
socketio = require('socket.io')
agent    = require 'superagent';

# Defaults
upstreamPort = 1409
mgmtPort = 1410
httpsPort = 8080


# Initialize express https server to serve socket.io libs
server  = express()
privateKey = fs.readFileSync('/etc/pki/tls/private/localhost.key').toString()
certificate = fs.readFileSync('/etc/pki/tls/certs/localhost.crt').toString()
credentials = {
  key: privateKey,
  cert: certificate
}
session = "rio_session=AmVcNFAxUTEGK1UkUWxQZw9uUDlWdwAmATUAfg18ADtXOlI5WQFUOQNhAXEAbgYvBmpXZgYzUGwOfVttADAEM1c%2FAz1SYFEzBDIFZAQxUWwCMFw3UGdROwZiVWNRMFAyD2tQNlY0ADABYwA8DWoANldhUjJZbVQ2Az0BcQBuBi8GaldkBjFQbA59W2EAcwQOV2cDalI0UXEEYwVzBHBRdwI%2FXH1QP1E6BmVVbVF0UGQPblA3VnsAZwFjADgNIQBjV2RSYllwVGEDMwFmAHcGZwYjV28GMFBmDmVbKgB2BCJXYwN8Ug9RYgRhBWUEbVEhAiZcNVB2UTEGYVVmUW5QbA98UE5WOgAvATkAYQ1jADNXelJiWXBUYAMlAXsAGAY9BjNXPAZvUCIOMFt7AGsEalcmA0dSPlF3BGMFbAQjURgCZVxtUCVRRAYDVXdRDlB2D29QM1YKAG0BDwA%2FDSYAclcUUidZLlQ8A2ABBAAwBj4GG1c8BnVQeQ5qWzsANAR%2FVzQDNlJwUSsETQVIBFdRGAJIXCJQJVFnBjlVPFEzUHYPGVBmVjYAPgE%2FACQNLwARVz1SJVkxVD0DYAF8AGcGagZ%2BV2UGL1BnDmxbMQA7BH9XNgMuUgNRYgRgBWEEcVE8AitcO1A2UTwGflVlUW5QdA9lUHBWbwBkAWMANw0tAD5XNFIkWSpUDwNkATAAIQY1BiZXPAZ1UC8OfVszAGoEa1c3Az1SZVE6BDAFNAQyUWMCMFw8UD5Rdg%3D%3D"

# Start the https server
https = http.createServer(credentials, server)
https.listen(httpsPort)
console.log 'https server serving socket.io listening on ' + httpsPort
# Bind socket.io to https server
io    = socketio.listen(https)
io.set 'log level', 1


# Intialize management console
# Completely unsafely evals all text sent to it as javascript,
# which gives you the ability to peek at things while its running

mgmt = net.createServer (stream) ->
  # Only accept connections from localhost for "security"
  if stream.remoteAddress == '127.0.0.1'
    stream.setEncoding 'ascii'
    stream.on 'data', (incomingData) ->
      incomingData.replace /\n/g, ''
      try
        eval incomingData
      catch e
        console.log 'bad command', e
# Start management console
mgmt.listen mgmtPort
console.log 'Management port listening on ' + mgmtPort

# Initialize TCP socket to listen for downstream data sources
# trying to send data northbound to the clients
listener = net.createServer (stream) ->
  stream.setEncoding 'ascii'
  stream.on 'data', (incomingData) ->
    incomingData.replace /\n/g, ''
    try
      data = JSON.parse incomingData
      validate data, ->
        console.log data
        data && send data
    catch e
      console.log 'Unable to parse and/or validate data'
listener.listen upstreamPort
console.log 'Upstream port listening on ' + upstreamPort

# Setup proxy behavior
# Bind listener to new client connection event
io.sockets.on 'connection', (socket) ->
  
  # Tell the client the server is ready for setup info
  socket.emit 'syn'
  
  # Listen for the setup info
  socket.on 'synack', (data) ->
    console.log data.userName, 'connected'
    # Store session info in socket data store
    socket.set 'userId', data.userId
    socket.set 'userName', data.userName
    socket.set 'session', data.session

  socket.on 'rioSocket', (config) ->
    # We need to accomodate port tunnels, so strip 
    # the port information out of the URL before we try
    test = config.url.match /(.*)(:[0-9]+)(\/.*)/
    if test
      port = test[2]
      if port
        config.newUrl = test[1] + test[3]
    url = config.newUrl || config.url

    # take the incoming url and proxy the request
    # Set the outgoing header to the incoming header for auth
    # Send the request and set up a callback for the response
    agent.post(url)
      .set('Cookie', config.session)
      .send()
      .end (err, res) ->
        if err
          socket.emit 'requestFailure', {error: err}
          console.log 'config: ', config
          console.log 'post error: ', err
        else
          try
            if config.newUrl
              # delete the temp url so that the returned 
              # config object goes back out the same way it
              # came in
              delete config.newUrl

            socket.emit 'rioSocketResponse', {
              status: res.status,
              response: JSON.parse(res.text),
              headers: res.header,
              config: config
            }            
          catch e
            socket.emit 'parseFailure', {error: e }
            console.log 'parse failure: ', config.url
            console.log res.text

# Helper function to emit the data to all (or a specific) user(s)
send = (data) ->
  _.each io.sockets.sockets, (socket) ->
    # If the send req has a session to target, only send to that session
    if socket.store && socket.store.data && socket.store.data.session
      if socket.store.data.session == data.session
        socket.emit data.channel, data
    # Else, broadcast the message to all connected sockets
    else
      socket.emit data.channel, data

# Validation function makes sure an incoming payload has
# the proper properties (returning the payload), otherwise it gets 
# dropped on the floor returning null
validate = (data, callback) ->

  # channel must be present and either 'info' or 'data'
  channelTest = if data.channel == 'info' || data.channel == 'data' then true else false
  if !channelTest
    console.log 'Failed channel test'
    console.log data.channel
  
  # origin must be supplied and not empty
  originTest if data.origin then true else false
  if !originTest
    console.log 'Failed origin test'
    console.log data.origin

  valid = channelTest && originTest;

  if valid
    callback data
  else
    callback null
