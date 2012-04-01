# Set export objects for node and coffee to a function that generates a sfw server.
module.exports = exports = (argv) ->
  #### Dependencies ####
  # anything not in the standard library is included in the repo, or
  # can be installed with an:
  #     npm install
  express = require('express')
  path = require('path')
  http = require('http')
  url = require('url')
  hbs = require('hbs')
  spawn = require('child_process').spawn
  # Create the main application object, app.
  app = express.createServer()
  # defaultargs.coffee exports a function that takes the argv object that is passed in and then does its
  # best to supply sane defaults for any arguments that are missing.
  argv = require('./defaultargs')(argv)

  #### State ####
  # Stores in-memory state
  content = []
  events = []
  files = []
  
  newContent = (body) ->
    id = content.length
    # Wrapped in array because it's version 0
    content.push []
    updateContent id, body
    id
  updateContent = (id, body) ->
    resource = content[id]
    ver = resource.length
    resource.push {
      'body': body
    }
    ver
  newEvent = (message, originUrl, status = 'PROCESSING') ->
    console.log("New Event: #{message}")
    id = events.length
    events.push
      message: message
      status: status
      created: new Date()
      origin: originUrl
    id

  updateEvent = (id, message, status = 'PROCESSING', url = null) ->
    console.log("Updating Event #{id}: #{message}")
    events[id].message = message
    events[id].status = status
    events[id].modified = new Date()
    if url
      events[id].url = url

  newFile = (body) ->
    id = files.length
    # Wrapped in array because it's version 0
    files.push body
    id
  remoteGet = (remoteUrl, event, cb) ->
    getopts = url.parse(remoteUrl)
    updateEvent(event, 'Requesting remote resource')
    
    # TODO: This needs more robust error handling, just trying to
    # keep it from taking down the server.
    http.get(getopts, (resp) ->
      responsedata = ''
      resp.on('data', (chunk) ->
        responsedata += chunk
        updateEvent(event, 'Getting Data')
      )
      resp.on('error', (e) ->
        updateEvent(event, "Error: #{JSON.stringify(e)}", 'FAILED')
        cb(e)
      )
      resp.on('end', ->
        if responsedata
          updateEvent(event, 'Got the resource')
          cb(null, responsedata, resp.statusCode)
        else
          updateEvent(event, "Error: Not Found", 'FAILED')
          cb(null, 'Page not found', 404)
      )
    ).on('error', (e) ->
      updateEvent(event, "Error: #{JSON.stringify(e)}", 'FAILED')
      cb(e)
    )

  #### Express configuration ####
  # Set up all the standard express server options,
  # including hbs to use handlebars/mustache templates
  # saved with a .html extension, and no layout.
  app.configure( ->
    app.set('views', path.join(__dirname, '..', '/views'))
    app.set('view engine', 'hbs')
    app.register('.html', hbs)
    app.set('view options', layout: false)
    app.use(express.cookieParser())
    app.use(express.bodyParser())
    app.use(express.methodOverride())
    app.use(express.session({ secret: 'notsecret'}))
    app.use(app.router)
    app.use(express.static(argv.c))
  )

  ##### Set up standard environments. #####
  # In dev mode turn on console.log debugging as well as showing the stack on err.
  app.configure('development', ->
    app.use(express.errorHandler({ dumpExceptions: true, showStack: true }))
    argv.debug = console? and true
  )

  # Show all of the options a server is using.
  console.log argv if argv.debug

  # Swallow errors when in production.
  app.configure('production', ->
    app.use(express.errorHandler())
  )

  #### Routes ####
  # Routes currently make up the bulk of the Express port of
  # Smallest Federated Wiki. Most routes use literal names,
  # or regexes to match, and then access req.params directly.

  ##### Redirects #####
  # Common redirects that may get used throughout the routes.
  app.redirect('index', (req, res) ->
    '/oops'
  )

  ##### Get routes #####
  # Routes have mostly been kept together by http verb, with the exception
  # of the openID related routes which are at the end together.

  generatePdf = (resourceUrl) ->
    pdfEvent = newEvent('Generating PDF', resourceUrl)
    remoteGet "#{argv.u}/pdf/derive?url=#{resourceUrl}", pdfEvent, (err, text, statusCode) ->
      updateEvent(pdfEvent, "PDF Request Sent!", 'SUCCESS', text)
  
  app.get('/derive', (req, res) ->
    originUrl = req.query.url
    event = newEvent('Getting remote resource', originUrl)
    remoteGet originUrl, event, (err, text, statusCode) -> 
      if text
        # TODO: Parse the HTML using http://css.dzone.com/articles/transforming-html-nodejs-and
        id = newContent(text)
        derivedUrl = "#{argv.u}/c/#{id}@0"
        updateEvent(event, 'Derived!', 'SUCCESS', derivedUrl)
        generatePdf(derivedUrl)
      else
        updateEvent(event, "Error: #{JSON.stringify(err)}", 'FAILED')
    res.send "#{argv.u}/events/#{event}"
  )

  # For debugging
  app.get('/c/', (req, res) ->
    res.send content
  )

  app.get('/c/:id([0-9]+)(@:ver([0-9]+))?.:format?', (req, res) ->
    ver = req.param('ver', "@#{content[req.params.id].length - 1}")
    ver = ver[1..ver.length] # split off the '@' character
    res.send content[req.params.id][ver].body
  )

  app.get('/events/:id([0-9]+)?', (req, res) ->
    if req.params.id
      res.send JSON.stringify(events[req.params.id])
    else
      res.send JSON.stringify(events)
  )

  ##### Post routes #####

  app.post('/c/:id([0-9]+)', (req, res) ->
    body = req.body.body
    ver = updateContent(req.params.id, body)
    
    generatePdf("#{argv.u}/c/#{req.params.id}@#{ver}")
    res.send "#{argv.u}/c/#{req.params.id}@#{ver}"
  )

  # Traditional request to / redirects to index :)
  app.get('/', (req, res) ->
    res.redirect('index')
  )

  #### PDF "repo" ####
  # Fortunately we just need to implement "derive"
  # We can piggy back on the in-mem event system
  
  app.get('/files/:id([0-9]+)', (req, res) ->
    res.send files[req.params.id]
  )
  
  app.get('/pdf/derive', (req, res) ->
    originUrl = req.query.url
    event = newEvent('Getting remote resource for PDF', originUrl)
    # Send the HTML to the PDF script
    pdf = spawn(argv.pdfgen, [ '-v', '--output=/dev/stdout', '/dev/stdin' ])
    remoteGet originUrl, event, (err, text, statusCode) -> 
      if text
        updateEvent(event, "Got data. Writing to prince #{text.length} chars")
        pdf.stdin.write(text)
        pdf.stdin.end()
      else
        updateEvent(event, "Error: #{JSON.stringify(err)}", 'FAILED')
        pdf.exit()

    pdfContent = ''
    pdf.stdout.on 'data', (data) ->
      pdfContent += data
    pdf.stderr.on 'data', (data) ->
      updateEvent(event, "Warning: #{data}")
    
    pdf.on 'exit', (code) ->
      if 0 == code
        id = newFile(pdfContent)
        fileUrl = "#{argv.u}/files/#{id}"
        updateEvent(event, 'PDF Done!', 'SUCCESS', fileUrl)
      else
        updateEvent(event, "Exit Code: #{code}.\n" + events[event].message, 'FAILED')

    res.send "#{argv.u}/events/#{event}"
  )
  
  #### Admin Page ####
  app.get('/admin', (req, res) ->
    res.render('admin.html', {}) # {} is vars
  )
  
  #### Start the server ####

  app.listen(argv.p, argv.o if argv.o)
  # When server is listening emit a ready event.
  app.emit "ready"
  console.log("Server listening on #{app.address().port} in mode: #{app.settings.env}")

  # Return app when called, so that it can be watched for events and shutdown with .close() externally.
  app
