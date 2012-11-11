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
  cleanupHTML = require('./util').cleanupHTML
  remoteGet   = require('./util').remoteGet
  asyncDeposit = require('./util').asyncDeposit

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

  # The prefix for "published" content (ie "/content/1234")
  CONTENT = 'content'

  # Deposit either a new piece of content (>=1) or new versions of existing content
  #
  # The minimum information that needs to be conveyed is:
  # - The payload (zip)
  # - For each piece of content whether it's a new piece of content or updating
  #     an existing piece of content
  # - How to find each piece of content
  #
  # 'deposit' is my way of implementing the PUBLISH/SAVE features of the unpub/pub repos.
  #
  # This can be any URL (for federation)
  # It can also be several URLs.
  # Each query parameter is either an id (in which case it's an update) or "new" in which case it's new content
  #
  # Structure of the POST parameters:
  # 'archive' = BINARY_ZIP_FILE : We're getting a zip file.
  #                 If there are no other POST parameters then
  #                 create new content from all the HTML files in the zip
  #                 (ie EPUB import).
  # ID = VALUE : This tells the deposit where to get the content (VALUE)
  #               and what to do with it (ID)
  #
  # Possible ID's:
  #   'new' : The content doesn't have an id yet so deposit will create one
  #   UUID  : This piece of published content is being updated.
  #           If the authenticated user has permissions to change this content
  #           then update it. Otherwise return an publish error.
  #
  # Possible VALUEs:
  #   URL   : A full URL to pull content from (this is the 'pull' API)
  #   HREF  : A path to an HTML file in the ZIP ('push' API)
  #   HTML_TEXT : The raw HTML to use
  #             (this is so the edit repo API is the same as the published repo API)
  #
  # Example POST parameters:
  #   archive : BINARY_DATA
  #   'col01' : 'toc.html'
  #   'm1234' : 'chapters/ch1.html'
  #   'm5678' : 'chapters/ch2.html'
  #   new     : 'chapters/ch3.html'
  #   new     : 'chapters/ch4.html'
  #
  #  ---------- Some remote examples (these can be in the same POST)------------
  #   'm9003' : 'http://editor.cnx.org/content/2k3jh'
  #   new     : 'http://editor.cnx.org/content/9283y'
  #
  #  ---------- Sending the HTML directly (think 'saving'; can also be in same POST)------------
  #   new     : '<html><body>Hello World</body></html>'
  #   '2k3jh' : '<html><body>Hello There Cruel World</body></html>'
  #
  app.post('/deposit', authenticated, (req, res, next) ->
    HTML_FILE_NAME = /\.x?html?$/

    # ------------------------------
    # Start figuring out what content we have and if we have permission to update it
    # ------------------------------

    # First make sure the user has permission to change all the content that is being updated
    postParams = req.body or []
    for id of postParams
      if 'new' != id and not canChangeContent(id, req.user)
        res.send "ERROR: You do not have permission to change #{id}"
        return

    # ------------------------------
    #  Build dictionary of content to deposit
    # ------------------------------

    # Next we need to build a dictionary of {id -> how-to-get-the-content}
    # This is used by the renaming pass to convert local paths (in the zip) to the
    # published id's.
    # During this phase new content is given a fresh id.

    class HrefLookup
      constructor: ->
        @map = {}
      isEmpty: () -> @map ? true: false
      # A way to iterate over all the content
      each: (iterator) ->
        for href, value of @map
          iterator(href, value)
      # Put a new piece of content in
      # Creates a new id if it is new content
      # Creates a new version if it is updating existing content
      put: (href, id=null) ->
        promise = new Promise()
        if null == id
          id = newContent(promise)
          ver = 0
        else
          ver = newContentVersion(id, promise)
        @map[href] = { id: id, ver: ver, promise: promise }
      getId:      (href) -> @map[href].id
      getVer:     (href) -> @map[href].ver
      getPromise: (href) -> @map[href].promise

    # Populate the hrefLookup object using the POST parameters
    hrefLookup = new HrefLookup()
    for id, hrefs of postParams
      # hrefs could either be a string or an array of strings (if id='new')

      # Either it's new content or it's a new version of existing content
      if id == 'new'
        if hrefs not instanceof Array
          hrefs = [ hrefs ]
        # For each piece of new content deposit it and get back the id
        for href in hrefs
          # TODO: support subdirs in the ZIP. href = context.goInto(href).basePath
          if href # Each of these URL's could be the empty string. If so, ignore it
            hrefLookup.put(href)
      else
        if hrefs instanceof Array
          throw new Error('Cannot update the same content more than once in a single deposit')
        href = hrefs
        hrefLookup.put(href, id)


    # If an archive was provided then open it up
    hasArchive = req.files and req.files['archive'] and req.files['archive'].size
    archiveZip = null
    if hasArchive
      console.log "Received file named #{req.files['archive'].name} with size #{req.files['archive'].size}"
      archiveZip = new AdmZip(req.files['archive'].path)

      # If an archive is sent and no POST parameters were specified then just include
      # all HTML files in the archive
      if hrefLookup.isEmpty()
        for entry in archiveZip.getEntries()
          continue if entry.name[0] == '.' # Skip hidden files
          if HTML_FILE_NAME.test entry.name
            console.log "No URLs specified, adding HTML file from Zip named #{entry.entryName}"
            hrefLookup.put(entry.entryName)


    # ------------------------------
    #  Done preparing
    # (that's all we can do synchronously)
    # ------------------------------

    # Fire off a worker and return the list of id's and versions
    # so the user can monitor the progress of publishing their set of content

    setTimeout (-> asyncDeposit(argv, hrefLookup, archiveZip)), 10

    # Return a mapping of uploaded URL/hrefs to content URLs
    ret = {}
    hrefLookup.each (href, value) ->
      id = value.id
      ver = value.ver
      ret[href] = "/#{ CONTENT }/#{id}@#{ver}"

    # Return a href -> id@ver dictionary of everything submitted
    # Shortcut if only 1 piece of content was sent
    if 1 == Object.keys(ret).length
      res.send ret[Object.keys(ret)[0]]
    else
      res.send JSON.stringify(ret)
  ) # END app.post('/deposit'

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
    if canChangeContent(id, req.user)
      html = req.body.body
      task = new Promise()
      task.work 'Committing new version'
      ver = newContentVersion(id, promise)
      resourceRenamer = (href, callback) -> callback(null)
      cleanupHTML(argv, html, task, resourceRenamer, (cleanedHTML) ->
        promise.finish(cleanedHTML) # Don't send a set of new users
        newUrl = "#{argv.u}/#{ CONTENT }/#{id}@#{ver}"
        #TODO request a PDF to be generated
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

  app.get('/resource/:id([0-9]+)', (req, res) ->
    # Set the mimetype for the resource
    id = req.params.id
    console.log "Getting resource id=" + id
    resource = resources[id]
    res.contentType resource.contentType
    res.send resource.content
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
