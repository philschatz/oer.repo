# Set export objects for node and coffee to a function that generates a sfw server.
module.exports = exports = (argv) ->
  #### Dependencies ####
  # anything not in the standard library is included in the repo, or
  # can be installed with an:
  #     npm install
  express     = require('express')
  path        = require('path')
  url         = require('url')
  hbs         = require('hbs')
  fs          = require('fs') # Just to load jQuery
  Q           = require('q')  # Promises, promises
  # Authentication machinery
  passport    = new (require('passport')).Passport()
  OpenIDstrat = require('passport-openid').Strategy

  # Local util objects/functions
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
  
  newContent = (user, body) ->
    id = content.length
    # Wrapped in array because it's version 0
    content.push []
    updateContent id, body, [ user ]
    id
  updateContent = (id, body, users=null) ->
    resource = content[id]
    ver = resource.length
    newVer =
      users: users
      body: body
    # If updating content and not changing the set of allowed users
    # Just use the previous set of users
    if not users
      newVer.users = resource[ver - 1].users
    resource.push newVer
    ver
  # Checks if a given user can modify a given piece of content
  canChangeContent = (id, user) ->
    resource = content[id]
    return resource[resource.length - 1].users.indexOf user >= 0

  #### Authentication Functions ####

  # For requests that need to be authenticated, add this into the pipe
  # by the owner, and returns 403 if someone else tries.
  authenticated = (req, res, next) ->
    if req.isAuthenticated() or argv.debug
      next()
    else res.send('Access Forbidden', 403)
    #next()

  # Simplest possible way to serialize and deserialize a user. (to store in a session)
  passport.serializeUser( (user, done) ->
    done(null, user.id)
  )
  passport.deserializeUser( (id, done) ->
    done(null, {id})
  )

  # Tell passport to use the OpenID strategy.
  passport.use(new OpenIDstrat({
    returnURL: "#{argv.u}/login/openid"
    realm: "#{argv.u}"
    identifierField: 'identifier'
  },
  ((id, done) ->
    console.log "Authenticated as #{ id }" if argv.debug
    done(null, {id})
  )))

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
    app.use(passport.initialize())
    app.use(passport.session()) # Must occur after express.session()
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
    remoteGet "#{argv.u}/pdf/deposit?url=#{resourceUrl}", pdfTask, (err, text, statusCode) ->
      pdfTask.finish "PDF Request Sent!", text
  
  # The prefix for "published" content (ie "/content/1234")
  CONTENT = "content"
  
  # Create a new resource from scratch
  app.post('/create', authenticated, (req, res) ->
    html = req.body.body
    task = new Task('Creating new Content')
    task.work('Cleaning up the HTML')
    cleanupHTML(html, task, (cleanHtml, links) ->
      id = newContent(req.user, cleanHtml)
      depositedUrl = "#{argv.u}/#{ CONTENT }/#{id}@0"
      task.finish 'Published!', depositedUrl
      #task.links = links # For debugging
      # Deriving a copy doesn't depend on generating a PDF
      requestPdf(depositedUrl)
    )
    res.send "#{argv.u}/tasks/#{task.id}"
  )

  # Deposit either a new piece of content or a new version of existing content
  # This can be any URL (for federation)
  # It can also be several URLs.
  # Each query parameter is either an id (in which case it's an update) or "new" in which case it's new content
  app.get('/deposit', authenticated, (req, res) ->
    originUrl = req.query.url
    task = new Task('Depositing content', originUrl)
    task.work 'Getting remote resource'
    # promises will eventually be an array of id's pointing to content that has been imported
    idsPromise = []
    
    class Context
      goInto: (href) ->
      getData: (callback) ->
    
    class UrlContext extends Context
      constructor: (@task, @baseUrl) ->
      goInto: (href) ->
        new UrlContext(@task, url.resolve(@baseUrl, href))
      getData: (callback) ->
        remoteGet @baseUrl, task, callback
    class PathContext extends Context
      constructor: (@zipFile, @basePath) ->
      goInto: (href) ->
        new PathContext(@zipFile, path.normalize(path.join(@basePath, href)))
      getData: (callback) ->
        @zipFile.readFileAsync @basePath, (data) ->
          callback(data?, data)
    
    # First, invert the query string so the dictionary is { depositURL -> repoId }
    contentMap = {}
    zipFile = null
    for id, urls of req.query
      # Either it's new content or it's a new version of existing content
      if id == 'url'
        if urls not instanceof Array
          urls = [ urls ]
        # For each piece of new content deposit it and get back the id
        for originUrl in urls
          contentMap[originUrl] = id
      else if id == 'body'
        zipFile = new AdmZip(urls) # TODO: convert POST param to Buffer
      else
        contentMap[urls] = id
  
    for contentUrl, id of contentMap
      scopingHack=(contentUrl, id) -> # Grr, stupid scoping 'issue' with Javascript loops and closures...
        contentUrl = url.parse(contentUrl)
        if contentUrl.hostname
          context = new UrlContext(task, contentUrl)
        else if zipFile
          context = new PathContext(zipFile, url.pathname)
        else throw new Error('Specified href to content without providing a zip payload or a hostname to pull from')

        deferred = Q.defer()
        idsPromise.push deferred.promise
        context.getData (err, text, statusCode) ->
          if text
            # TODO: Parse the HTML using http://css.dzone.com/articles/transforming-html-nodejs-and
            task.work('Cleaning up the HTML')
            cleanupHTML(text, task, (cleanHtml, links) ->
              if id == 'url'
                id = newContent(req.user, cleanHtml)
                ver = 0
              else
                ver = updateContent(id, cleanHtml)
              depositedUrl = "#{argv.u}/#{ CONTENT }/#{id}@#{ver}"
              task.work 'Deposited! at ' + depositedUrl
              deferred.resolve
                id: id
                ver: ver
            )
      scopingHack(contentUrl, id)

    task.wait("Trying to deposit #{idsPromise.length} URLs #{req.query}")
    Q.all(idsPromise)
    .then( (o) -> 
      console.log 'Finished depositing. Got back:', o
      urls = []
      for content in o
        depositedUrl = "#{argv.u}/#{ CONTENT }/#{content.id}@#{content.ver}"
        urls.push(depositedUrl)
        # Deriving a copy doesn't depend on generating a PDF
        requestPdf(depositedUrl)
        
      task.finish 'All Deposited!', urls)
    .fail (o) -> task.error 'Problem depositing some content'
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

  app.post("/#{ CONTENT }/:id([0-9]+)", authenticated, (req, res) ->
    if canChangeContent req.params.id, req.user
      html = req.body.body
      task = new Task('Committing new version')
      cleanupHTML(html, task, (cleanedHTML, links) ->
        task.links = links
        ver = updateContent(req.params.id, cleanedHTML) # Don't send a set of new users
        newUrl = "#{argv.u}/#{ CONTENT }/#{req.params.id}@#{ver}"
        requestPdf(newUrl)
        task.finish 'Content updated!', newUrl
      )
      res.send "#{argv.u}/tasks/#{task.id}"
    else
      # User is not allowed to make changes
      res.send 403
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
  
  app.get('/pdf/deposit', (req, res) ->
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

  ##### Routes used for openID authentication #####
  # Redirect to oops when login fails.
  app.post('/login',
    passport.authenticate('openid', { failureRedirect: '/error'}),
    (req, res) ->
      res.redirect('index')
  )

  # Route that the openID provider redirects user to after login.
  app.get('/login/openid',
    passport.authenticate('openid', { failureRedirect: '/error'}),
    (req, res) ->
      res.redirect('index')
  )

  # Logout when /logout is hit with any http method.
  app.all('/logout', (req, res) ->
    req.logout()
    res.redirect('index')
  )


  #### Start the server ####

  app.listen(argv.p, argv.o if argv.o)
  # When server is listening emit a ready event.
  app.emit "ready"
  console.log("Server listening in mode: #{app.settings.env}")

  # Return app when called, so that it can be watched for events and shutdown with .close() externally.
  app
