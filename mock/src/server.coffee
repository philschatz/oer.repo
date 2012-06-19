# Set export objects for node and coffee to a function that generates a sfw server.
module.exports = exports = (argv) ->
  #### Dependencies ####
  # anything not in the standard library is included in the repo, or
  # can be installed with an:
  #     npm install
  express     = require('express')
  path        = require('path')
  hbs         = require('hbs')
  fs          = require('fs') # Just to load jQuery

  Task        = require('./util').Task
  cleanupHTML = require('./util').cleanupHTML
  remoteGet   = require('./util').remoteGet
  generatePDF = require('./util').generatePDF

  #### State ####
  # Stores in-memory state
  content = []
  # The following are imported because the Task adds to the array
  files   = require('./util').files
  events  = require('./util').events

  # Create the main application object, app.
  app = express.createServer()
  # defaultargs.coffee exports a function that takes the argv object that is passed in and then does its
  # best to supply sane defaults for any arguments that are missing.
  argv = require('./defaultargs')(argv)
  
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
  # Routes currently make up the bulk of the Express
  # server. Most routes use literal names,
  # or regexes to match, and then access req.params directly.

  ##### Redirects #####
  # Common redirects that may get used throughout the routes.
  app.redirect('index', (req, res) ->
    '/admin'
  )

  ##### Get routes #####
  # Routes have mostly been kept together by http verb

  # Helper that issues a PDF gen request to the PDF "service"
  requestPdf = (resourceUrl) ->
    pdfTask = new Task('Requesting PDF', resourceUrl)
    remoteGet "#{argv.u}/pdf/derive?url=#{resourceUrl}", pdfTask, (err, text, statusCode) ->
      pdfTask.finish "PDF Request Sent!", text
  
  # The prefix for "published" content (ie "/content/1234")
  CONTENT = "content"
  
  # Create a new resource from scratch
  app.post('/create', (req, res) ->
    html = req.body.body
    task = new Task('Creating new Content')
    task.work('Cleaning up the HTML')
    cleanupHTML(html, task, (cleanHtml, links) ->
      id = newContent(cleanHtml)
      derivedUrl = "#{argv.u}/#{ CONTENT }/#{id}@0"
      task.finish 'Published!', derivedUrl
      #task.links = links # For debugging
      # Deriving a copy doesn't depend on generating a PDF
      requestPdf(derivedUrl)
    )
    res.send "#{argv.u}/tasks/#{task.id}"
  )

  # Derive a copy of an existing resource
  # This can be any URL (for federation)
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
          derivedUrl = "#{argv.u}/#{ CONTENT }/#{id}@0"
          task.finish 'Derived!', derivedUrl
          #task.links = links # For debugging
          # Deriving a copy doesn't depend on generating a PDF
          requestPdf(derivedUrl)
        )
      else
        console.log("Error: derive failed because no HTML was received")
        task.fail err
    res.send "#{argv.u}/tasks/#{task.id}"
  )

  # For debugging
  app.get("/#{ CONTENT }/", (req, res) ->
    res.send content
  )

  app.get("/#{ CONTENT }/:id([0-9]+)(@:ver([0-9]+))?", (req, res) ->
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

  app.post("/#{ CONTENT }/:id([0-9]+)", (req, res) ->
    html = req.body.body
    task = new Task('Committing new version')
    cleanupHTML(html, task, (cleanedHTML, links) ->
      task.links = links
      ver = updateContent(req.params.id, cleanedHTML)
      newUrl = "#{argv.u}/#{ CONTENT }/#{req.params.id}@#{ver}"
      requestPdf(newUrl)
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
    # Set the mimetype for PDF
    res.contentType 'application/pdf'
    res.send files[req.params.id]
  )
  
  app.get('/pdf/derive', (req, res) ->
    originUrl = req.query.url
    task = new Task('PDFGEN', originUrl)
    generatePDF argv, task, originUrl
    res.send "#{argv.u}/tasks/#{task.id}"
  )
  
  #### Admin Page ####
  app.get('/admin', (req, res) ->
    res.render('admin.html', {}) # {} is vars
  )

  app.get('/jquery-latest.js', (req, res) ->
    res.send(fs.readFileSync(__dirname+ '/../lib/jquery.min.js', 'utf-8'))
  )


  #### Start the server ####

  app.listen(argv.p, argv.o if argv.o)
  # When server is listening emit a ready event.
  app.emit "ready"
  console.log("Server listening on #{app.address().port} in mode: #{app.settings.env}")

  # Return app when called, so that it can be watched for events and shutdown with .close() externally.
  app
