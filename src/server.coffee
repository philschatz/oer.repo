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
  AdmZip      = require('adm-zip')
  # Authentication machinery
  passport    = new (require('passport')).Passport()
  OpenIDstrat = require('passport-openid').Strategy

  # Local util objects/functions
  Promise     = require('./util').Promise
  newResource = require('./util').newResource
  cleanupHTML = require('./util').cleanupHTML
  remoteGet   = require('./util').remoteGet
  generatePDF = require('./util').generatePDF

  #### State ####
  # Stores in-memory state
  content = []
  # The following are imported because the Task adds to the array
  resources   = require('./util').resources
  events  = require('./util').events

  # Create the main application object, app.
  app = express.createServer()

  # bodyParser in connect 2.x uses node-formidable to parse 
  # the multipart form data.
  # Used for getting Zips deposited via POST
  app.use(express.bodyParser())

  # defaultargs.coffee exports a function that takes the argv object that is passed in and then does its
  # best to supply sane defaults for any arguments that are missing.
  argv = require('./defaultargs')(argv)
  
  newContent = (promise) ->
    id = content.length
    # Wrapped in array because it's version 0
    content.push [ {users: null, body: promise} ]
    id
  newContentVersion = (id, promise, users=null) ->
    versions = content[id]
    ver = versions.length
    newVer =
      users: users
      body: promise
    # If updating content and not changing the set of allowed users
    # Just use the previous set of users
    if not users
      newVer.users = versions[ver - 1].users
    versions.push newVer
    ver
    
  # Checks if a given user can modify a given piece of content
  canChangeContent = (id, user) ->
    resource = content[id]
    return resource[resource.length - 1].users.indexOf user >= 0

  #### Authentication Functions ####

  # For requests that need to be authenticated, add this into the pipe
  # by the owner, and returns 403 if someone else tries.
  authenticated = (req, res, next) ->
    if req.isAuthenticated() or argv.x
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
    pdfTask = new Promise()
    pdfTask.work 'Requesting PDF'
    pdfTask.originUrl = resourceUrl
    remoteGet "#{argv.u}/pdf/deposit?url=#{resourceUrl}", pdfTask, (err, text, statusCode) ->
      pdfTask.finish "PDF Request Sent!", text.toString()
  
  # The prefix for "published" content (ie "/content/1234")
  CONTENT = "content"
  
  # Deposit either a new piece of content or a new version of existing content
  # This can be any URL (for federation)
  # It can also be several URLs.
  # Each query parameter is either an id (in which case it's an update) or "new" in which case it's new content
  app.post('/deposit', authenticated, (req, res, next) ->
    HTML_FILE_NAME = /\.x?html?$/
    # promises will eventually be an array of id's pointing to content that has been imported
    idsPromise = []
    
    class Context
      getBase: () ->
      goInto: (href) ->
      getData: (callback) ->
    
    class UrlContext extends Context
      constructor: (@task, @baseUrl) ->
      getBase: () -> url.format(@baseUrl)
      goInto: (href) ->
        new UrlContext(@task, url.resolve(@baseUrl, href))
      getData: (callback) ->
        remoteGet @baseUrl, @task, callback

    class SingleFileContext extends Context
      constructor: (@task, @htmlText) ->
      getBase: () -> '.'
      goInto: (href) ->
        new UrlContext(@task, url.parse(href))
      getData: (callback) ->
        callback(null, @htmlText)

    class PathContext extends Context
      constructor: (@task, @zipFile, @basePath) ->
      getBase: () -> @basePath
      goInto: (href) ->
        # Local files in the zip can either point to other local files
        # or to remote files.
        if url.parse(href).protocol
          new UrlContext(@task, url.parse(href))
        else
          new PathContext(@task, @zipFile, path.normalize(path.join(path.dirname(@basePath), href)))
      getData: (callback) ->
        entry = @zipFile.getEntry(@basePath)
        if entry
          # Try to get the data asynchronously since it uses native zlib
          # But if we get a bad CRC the async code throws an exception instead of returning the partial data
          # So, in that case, get the data synchronously (something is better than nothing?)
          
          # The next lines are commented because I apparently can't catch Errors
          #try
          #  entry.getDataAsync (data) ->
          #    callback(not data, data)
          #catch error
            console.log "The next line may cause a warning. Something to the effect of CRC32 checksum failed [filename]. Ignore it"
            data = entry.getData()
            callback(not data, data)
        else
          callback('Error: Could not find zip entry', "Error: Could not find zip entry #{@basePath}")
    
    # First, invert the query string so the dictionary is { depositURL -> repoId }
    contentMap = {}
    zipFile = null
    if req.files and req.files.archive and req.files.archive.size
      console.log "Received file named #{req.files.archive.name} with size #{req.files.archive.size}"
      zipFile = new AdmZip(req.files.archive.path)

    if req.body
      for id, urls of req.body
        # Either it's new content or it's a new version of existing content
        if id == 'new'
          if urls not instanceof Array
            urls = [ urls ]
          # For each piece of new content deposit it and get back the id
          for originUrl in urls
            # TODO: support subdirs in the ZIP. href = context.goInto(href).basePath
            if originUrl # Each of these URL's could be the empty string. If so, ignore it
              promise = new Promise()
              id = newContent(promise)
              contentMap[originUrl] = { id: id, ver: 0, promise: promise }
        else
          promise = new Promise()
          ver = newContentVersion(id, promise)
          contentMap[urls] = { id: id, ver: ver, promise: promise }
    
    # If they are uploading a zip and did not explicitly specify any html files, add them all
    if zipFile?
      # Check if any of the files to deposit are local (not an absolute URL and not raw HTML)
      foundLocalHref = false
      for href of contentMap
        if href[0] != '<' and not url.parse(href).protocol
          foundLocalHref = true
      if not foundLocalHref
        for entry in zipFile.getEntries()
          continue if entry.name[0] == '.' # Skip hidden files
          if HTML_FILE_NAME.test entry.name
            console.log "No URLs specified, adding HTML file from Zip named #{entry.entryName}"
            promise = new Promise()
            id = newContent(promise)
            contentMap[entry.entryName] = { id: id, ver: 0, promise: promise }
        
    doTheDeposit = () ->    
        for contentUrl, obj of contentMap
          id = obj.id
          contentTask = obj.promise

          contentTask.work 'Importing/Cleaning'
          scopingHack=(task, contentUrl, id) -> # Grr, stupid scoping 'issue' with Javascript loops and closures...
            href = url.parse(contentUrl)
            if contentUrl[0] == '<'
              context = new SingleFileContext(task, contentUrl)
            else if href.protocol
              # TODO: Split off the text after the last slash
              context = new UrlContext(task, href)
            else if zipFile
              # Verify the file exists in the zip
              if not zipFile.getEntry(href.pathname)
                task.fail "Uploaded zip file does not contain a file named #{href.pathname}"
              # TODO: Split off the text after the last slash
              context = new PathContext(task, zipFile, href.pathname)
            else task.fail 'Specified href to content without providing a zip payload or a hostname to pull from'
    
            deferred = Q.defer()
            idsPromise.push deferred.promise
            
            # This tool will "import" a resource (think image) pointed to by context/href (a remote URL or inside the Zip file)
            linkRenamer = (href, callback) ->
              # Links may contain '#id123' at the end of them. Split that off and retain it (TODO: Verify it later)
              [newHref, inPageId] = href.split('#')
              if newHref == ''
                # It's a local link. Don't change it.
                callback(false, href)
              else
                newHref = context.goInto(newHref).getBase()
                if newHref of contentMap
                  newId = contentMap[newHref].id
                  newHref = "#{newId}"
                  newHref += '#' + inPageId if inPageId?
                  callback(false, newHref)
                else if url.parse(newHref).protocol
                  callback(false, href)
                else
                  callback(true)
    
            resourceRenamer = (href, contentType, callback) ->
              context.goInto(href).getData (err, content) ->
                if not err
                  # "Import" the resource
                  rid = newResource(content, contentType, context.goInto(href).getBase())
                  callback(err, "/resource/#{rid}")
                else
                  console.warn "Error depositing resource because of status=#{err} (Probably missing file)"
                  # TODO: Fail at this point, but since test-ccap has missing images let it slide ...
                  callback(err, "Problem loading resource")
            
            context.getData (err, text, statusCode) ->
              if not err
                # TODO: Parse the HTML using http://css.dzone.com/articles/transforming-html-nodejs-and
                task.work('Cleaning up the HTML')
                promise = cleanupHTML(argv, text, task, resourceRenamer, linkRenamer)
                promise.then (cleanHtml) ->
                  task.work 'Cleaned up HTML.'
                  task.work "updateContent id=#{id} user=#{req.user}"
                  task.finish cleanHtml
              else
                task.fail("couldn't get data for some reason")
                
          scopingHack(contentTask, contentUrl, id)
    
        urls = []
        for id, obj of contentMap
          depositedUrl = "#{argv.u}/#{ CONTENT }/#{obj.id}@#{obj.ver}"
          urls.push(depositedUrl)
          # Deriving a copy doesn't depend on generating a PDF
          requestPdf(depositedUrl)
    
    setTimeout(doTheDeposit, 10)
    
    # Return a mapping of uploaded URL/hrefs to content URLs
    ret = {}
    for href, obj of contentMap
      ret[href] = "/#{ CONTENT }/#{obj.id}@#{obj.ver}"
    res.send JSON.stringify(ret)
  )

  # For debugging
  app.get("/#{ CONTENT }/", (req, res) ->
    # Build up a little map of all the promises (tasks)
    tasks = []
    for c in content
      promise = c[c.length-1].body
      tasks.push
        history:  promise.history
        created:  promise.created
        modified: promise.modified
        status:   promise.status
    res.send tasks
  )

  app.get("/#{ CONTENT }/:id([0-9]+)(@:ver([0-9]+))?", (req, res) ->
    id = req.params.id
    ver = req.param('ver', "@#{content[id].length - 1}")
    ver = ver[1..ver.length] # split off the '@' character
    body = content[id][ver].body # .body is a Promise
    body.send(res)
  )
  app.get("/#{ CONTENT }/:id([0-9]+)(@:ver([0-9]+))?.json", (req, res) ->
    id = req.params.id
    ver = req.param('ver', "@#{content[id].length - 1}")
    ver = ver[1..ver.length] # split off the '@' character
    body = content[id][ver].body # .body is a Promise
    res.send(body)
  )


  app.get('/tasks/:id([0-9]+)?', (req, res) ->
    if req.params.id
      res.send JSON.stringify(events[req.params.id])
    else
      res.send JSON.stringify(events)
  )

  ##### Post routes #####

  app.post("/#{ CONTENT }/:id([0-9]+)", authenticated, (req, res) ->
    id = req.params.id
    if canChangeContent id, req.user
      html = req.body.body
      task = new Promise()
      task.work 'Committing new version'
      ver = newContentVersion(id, promise)
      resourceRenamer = (href, callback) -> callback(null)
      cleanupHTML(argv, html, task, resourceRenamer, (cleanedHTML) ->
        promise.finish(cleanedHTML) # Don't send a set of new users
        newUrl = "#{argv.u}/#{ CONTENT }/#{id}@#{ver}"
        requestPdf(newUrl)
      )
      res.send "/#{ CONTENT }/#{id}@#{ver}"
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
  
  app.get('/resource/:id([0-9]+)', (req, res) ->
    # Set the mimetype for the resource
    id = req.params.id
    console.log "Getting resource id=" + id
    resource = resources[id]
    res.contentType resource.contentType
    res.send resource.content
  )
  
  app.get('/pdf/deposit', (req, res) ->
    originUrl = req.query.url
    task = new Promise()
    task.work 'PDFGEN'
    task.origin = originUrl
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
