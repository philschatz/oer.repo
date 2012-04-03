# Set export objects for node and coffee to a function that generates a sfw server.
module.exports = exports = (argv) ->
  #### Dependencies ####
  # anything not in the standard library is included in the repo, or
  # can be installed with an:
  #     npm install
  express = require('express')
  path = require('path')
  http = require('http')
  https = require('https')
  url = require('url')
  hbs = require('hbs')
  spawn = require('child_process').spawn
  jsdom = require('jsdom')
  EventEmitter = require('events').EventEmitter
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

  class Task extends EventEmitter
    constructor: (@title, @origin) ->
      @history = [] # Stores all the changes made to the event
      @status = 'PENDING'
      @created = @modified = new Date()
      # Push it into the array so admin can keep track of it
      events.push @
      @id = events.length - 1

    update: (message, status) ->
      if @status == 'FINISHED' or @status == 'FAILED'
        err = { event: @, message: 'This event already completed', newMessage: message, newStatus: status }
        console.log err
        throw err
      @message = message
      @modified = new Date()
      @status = status if status?
      @history.push(message)
      console.log "Event: #{@message}"
    
    work: (message, status = 'WORKING') ->
      @update(message, status)
      @emit('work')

    fail: (error) ->
      error = JSON.stringify(error) if not typeof error = 'string'
      @update(error, 'FAILED')
      @emit('end', 'FAILED')
    
    finish: (message, url) ->
      @update(message, 'FINISHED')
      @url = url
      @emit('end', 'FINISHED')
      
  newFile = (body) ->
    id = files.length
    # Wrapped in array because it's version 0
    files.push body
    id

  remoteGet = (remoteUrl, task, cb) ->
    getopts = url.parse(remoteUrl)
    task.work 'Requesting remote resource'
    task.url = remoteUrl
    
    protocol = if 'https:' == getopts.protocol then https else http
    # TODO: This needs more robust error handling, just trying to
    # keep it from taking down the server.
    protocol.get(getopts, (resp) ->
      responsedata = ''
      resp.on('data', (chunk) ->
        responsedata += chunk
        task.work 'Getting Data'
      )
      resp.on('error', (e) ->
        task.fail e
        cb(e)
      )
      resp.on('end', ->
        if responsedata
          task.work 'Got the resource'
          cb(null, responsedata, resp.statusCode)
        else
          task.fail "Resource Not Found"
          cb(null, 'Page not found', 404)
      )
    ).on('error', (e) ->
      task.fail e
      cb(e)
    )

  cleanupHTML = (html, task, callback) ->
    task.work 'Cleaning up HTML. Parsing...'
    doc = jsdom.jsdom(html, null, 
      features:
        FetchExternalResources: false # ['img']
        ProcessExternalResources: false
    )
    window = doc.createWindow()
    jsdom.jQueryify(window, (window, $) ->
      try
        $ = window.jQuery
        $('script').remove()
        # $('head').remove() # TODO: look up attribution here
        $('*[style]').removeAttr('style')
        
        task.work 'Cleaning up links'
        links = []
        $('a[href]').each (i, a) ->
          links.push $(a).attr('href')
        
        task.work 'Done cleaning'
        callback(doc.outerHTML, links)
      catch error
        task.fail error
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
    pdfTask = new Task('Requesting PDF', resourceUrl)
    remoteGet "#{argv.u}/pdf/derive?url=#{resourceUrl}", pdfTask, (err, text, statusCode) ->
      pdfTask.finish "PDF Request Sent!", text
  
  app.get('/derive', (req, res) ->
    originUrl = req.query.url
    task = new Task('Deriving a copy', originUrl)
    task.work 'Getting remote resource'
    remoteGet originUrl, task, (err, text, statusCode) -> 
      if text
        # TODO: Parse the HTML using http://css.dzone.com/articles/transforming-html-nodejs-and
        task.work('Cleaning up the HTML')
        cleanupHTML(text, task, (cleanHtml, links) ->
          id = newContent(cleanHtml)
          derivedUrl = "#{argv.u}/c/#{id}@0"
          task.finish 'Derived!', derivedUrl
          #task.links = links # For debugging
          # Deriving a copy doesn't depend on generating a PDF
          generatePdf(derivedUrl)
        )
      else
        task.fail err
    res.send "#{argv.u}/tasks/#{task.id}"
  )

  # For debugging
  app.get('/c/', (req, res) ->
    res.send content
  )

  app.get('/c/:id([0-9]+)(@:ver([0-9]+))?', (req, res) ->
    ver = req.param('ver', "@#{content[req.params.id].length - 1}")
    ver = ver[1..ver.length] # split off the '@' character
    res.send content[req.params.id][ver].body
  )

  app.get('/tasks/:id([0-9]+)?', (req, res) ->
    if req.params.id
      res.send JSON.stringify(events[req.params.id])
    else
      res.send JSON.stringify(events)
  )

  ##### Post routes #####

  app.post('/c/:id([0-9]+)', (req, res) ->
    html = req.body.body
    task = new Task('Committing new version')
    cleanupHTML(html, task, (cleanedHTML, links) ->
      task.links = links
      ver = updateContent(req.params.id, cleanedHTML)
      newUrl = "#{argv.u}/c/#{req.params.id}@#{ver}"
      generatePdf(newUrl)
      task.finish 'Content updated!', newUrl
    )
    res.send "#{argv.u}/tasks/#{task.id}"
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
    task = new Task('PDFGEN', originUrl)
    task.work 'Getting remote resource for PDF'
    # Send the HTML to the PDF script
    pdf = spawn(argv.pdfgen, [ '--no-network', '--input=html', '--verbose', '--output=/dev/stdout', '/dev/stdin' ])
    remoteGet originUrl, task, (err, text, statusCode) -> 
      if text
        task.work "Got data. Writing to prince #{text.length} chars"
        pdf.stdin.write(text)
        pdf.stdin.end()
      else
        task.fail err
        pdf.exit()

    pdfContent = ''
    pdf.stdout.on 'data', (data) ->
      pdfContent += data
    pdf.stderr.on 'data', (data) ->
      task.work "Warning: #{data}"
    
    pdf.on 'exit', (code) ->
      if 0 == code
        id = newFile(pdfContent)
        fileUrl = "#{argv.u}/files/#{id}"
        task.finish 'PDF Done!', fileUrl
      else
        task.fail "PDF Failed. Exit Code: #{code}.\n#{task.message}"

    res.send "#{argv.u}/tasks/#{task.id}"
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
