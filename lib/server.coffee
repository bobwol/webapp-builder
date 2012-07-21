BuildManager = require './BuildManager'
{ Builder } = require './Builder'
{ ClientManager } = require './ClientManager'
{ FileSystem, FileNotFoundException } = require './FileSystem'
Fallback = require './builders/Fallback'
Reporter = require './Reporter'
express = require 'express'
socketio = require 'socket.io'
path = require 'path'
url = require 'url'

exports.middleware = (args) ->
  clients = {}
  known_deps = {}

  manager = new BuildManager args

  if args.watchFileSystem
    client_manager = new ClientManager manager, args.socketIOManager

  if args.fallthrough is false
    fallback_builder = new Fallback '%%', [],
      manager: manager

  map_url_to_node = (url_string) ->
    url_string = url.parse(url_string).pathname
    url_string += "index.html" if url_string.substr(-1) == "/"
    url_string = path.join manager.getOption('targetPath'),
                    url_string.substring 1
    manager.fs.resolve url_string


  middleware = (req, res, next) ->
    target = map_url_to_node req.url

    if target.exists() and
       target.getStat().isDirectory() and
       request_url.substr(-1) != "/"
      # For directories, redirect to the trailing / form. This will cause us
      # to realize we are dealing with a directory and serve index.html
      # appropriately.
      res.redirect "#{req.url}/"
      res.end()
      return

    builder = manager.resolve target
    missing_files = []
    unless builder?
      builder = Builder.createBuilderFor manager, target, missing_files

    if builder?
      manager.reporter.debug "#{req.url} will be built by #{builder}"

    else if args.fallthrough is false
      builder = new Fallback target, [ ], manager: manager
      builder.impliedSources = (manager.fs.resolve f for f in missing_files)
      manager.register builder

    else
      return next()

    if req.headers.referer? and client_manager?
      referer = map_url_to_node req.headers.referer
      unless referer.equals target
        # Filter out refreshes
        client_manager.addClientSideDependency referer, target

    # Now that the rules are definitely set up, we can use BuildManager.make.
    manager.make target, (results) ->
      console.log results
      err = results[target.getPath()]
      return next err if err?
      target.getData (err, data) ->
        next err if err?

        if builder instanceof Fallback
          res.statusCode = 404
        if builder.getMimeType() is "text/html" and client_manager?
          data = data.toString() + client_manager.getTrailerFor builder
        res.setHeader 'Content-Type', builder.getMimeType()
        res.setHeader 'Content-Length', data.length
        res.write data
        res.end()

exports.standalone = (args) ->
  args.fallthrough = false
  # -v and -q will shift the log level from the default
  args.verbose = args.verbose + Reporter.INFO

  app = express.createServer()
  args.socketIOManager = socketio.listen app,
    'log level': 1

  app.use exports.middleware args
  app.use express.errorHandler
    showStack: true
    dumpExceptions: true

  server = app.listen args.port
  console.log "Server now live at http://localhost:#{server.address().port}/"
