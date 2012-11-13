# This file mostly deals with depositing a set of resources asynchronously.
# In this file are:
#
# 1. a `Promise` utility class that handles HTTP responses when a piece of content has not finished generating yet
# 2. `Context` utility classes for navigating a ZIP file or remote HTTP files
# 3. a `cleanupHtml` method that parses HTML into a DOM and uses jQuery to update links and references to resources
# 4. a `remoteGet` method that makes GET queries to remote URLs to get resources like images to store in the repository
# 5. the `asyncDeposit` method.

# ## Packages used
# For navigating zip files using local hrefs (like `../../ch2/index.html`)
path = require('path')
# For the `Promise` class
EventEmitter = require('events').EventEmitter
# For parsing and cleaning up the HTML
jsdom = require('jsdom')
# To wait until all links are renamed and resources imported
Q = require('q') # Promises, Promises

# These are packages used for remoteGet
http = require('http')
https = require('https')
url = require('url')

# The in-memory resources are stored here and are used here and in the server
module.exports.resources = resources = []

# ## Promise
# A Promise either returns a JSON object representing the status of the resource
# or the resource itself if processing is complete
#
# `.update/finish/fail` all update the state as the promise is being worked on
# `.send()` takes the HTTP Response object and writes either the JSON or the content.
module.exports.Promise = class Promise extends EventEmitter
  constructor: (prerequisite) ->
    @status = 'PENDING'
    @created = new Date()
    @history = []
    @isProcessing = true
    @data = null
    if prerequisite?
      that = @
      prerequisite.on 'update', (msg) -> that.update "Prerequisite update: #{msg}"
      prerequisite.on 'fail', () ->
        that.update 'Prerequisite task failed'
        that.fail()
      prerequisite.on 'finish', (_, mimeType) -> that.update "Prerequisite finished generating object with mime-type=#{mimeType}"

  # Send either the data (if available), or a HTTP Status with this JSON
  send: (res) ->
    if @isProcessing
      res.status(202).send @
    else if @data
      res.header('Content-Type', @mimeType)
      res.send @data
    else
      res.status(404).send @
  # Update the promise without completing it
  work: (message, @status='WORKING') ->
    @update(message)
    @emit('work')
  wait: (message, @status='PAUSED') ->
    @update(message)
    @emit('work')
  # Internal method that performs the update
  update: (msg) ->
    # If the promise has already completed then a call to this method is a bug that should be fixed
    if @status == 'FINISHED' or @status == 'FAILED'
      message = @history[@history.length-1]
      err = { event: @, message: "This event already completed with status #{@status} and message='#{message}'", newMessage: msg }
      console.log err
      throw err
    @modified = new Date()
    @history.push msg
    console.log msg
    if @history.length > 500
      @history.splice(0,1)
    @emit('update', msg)

  # Complete a Promise (task) because something went wrong.
  # If this is called the promise will return a 404.
  fail: (msg) ->
    @update msg
    @update 'FAILED!!!!!'
    @isProcessing = false
    @status = 'FAILED'
    @data = null
    @emit('fail')
  # Complete a Promise (task) because the resource or content was created.
  finish: (@data, @mimeType='text/html; charset=utf-8') ->
    @update "Generated file"
    @isProcessing = false
    @status = 'FINISHED'
    @emit('finish', @data, @mimeType)

# # Asynchronous Deposits
# This consists of several utility classes and methods outlined below.

# ### The HTML Scrubber

# This method cleans up HTML so links and resources point to the right place
# By using the Context class it can operate on a zip file *or* remote URLs.
#
# The cleanup steps are:
#
# 1. parse an HTML string using jsdom
# 2. use jQuery to find interesting nodes like links and images
# 3. change links so instead of pointing to resources in the zip they point to published content
# 4. get the bits for the image and store them in the /resources asynchronously
cleanupHTML = (html, task, resourceRenamer, linkRenamer, callback) ->
  task.work 'Cleaning up HTML. Parsing...'
  html = html.toString()
  # Start up a server-side HTML parser with a DOM
  jsdom.env html,
    features:
      FetchExternalResources: false # ['img']
      ProcessExternalResources: false
  , (errors, window) ->
    if errors
      task.work "Could not generate window.document.body for this HTML"
      callback(new Error('Could not generate window.document.body (usually a malformed HTML file'))

    errors = null # possibly set one if an error is caught
    newHtml = null
    promises = [] # Since converting images are asynchronous we use `Q.defer` to call the callback once all conversions are done
    try
      task.work 'Starting clean'
      # Attach jQuery to the DOM so we can manipulate the HTML
      $ = require('jQuery').create(window)
      $('script').remove()
      $('*[style]').removeAttr('style')

      newHrefs = {}
      # Clean up the links in the HTML
      task.work 'Cleaning up links'
      $('a[href]').each (i, a) ->
        $el = $(@)
        innerDeferred = Q.defer()
        promises.push innerDeferred.promise
        linkRenamer $el.attr('href'), (err, newHref) ->
          href = $el.attr('href')
          if href != newHref
            newHrefs[href] = newHref
            task.work "Changing link from #{href} to #{newHref}"
            $el.attr('href', newHref)
          innerDeferred.resolve newHref

      # Change img sources to point to local resources
      # and issue remote GET requests if they point to remote resources
      $('img[src]').each (i, a) ->
        $el = $(@)
        innerDeferred = Q.defer()
        promises.push innerDeferred.promise
        resourceRenamer $el.attr('src'), 'image/jpeg', (err, newHref) ->
          href = $el.attr('src')
          if href != newHref
            newHrefs[href] = newHref
            task.work "Changing image resource from #{href} to #{newHref}"
            $el.attr('src', newHref)
          innerDeferred.resolve newHref

      # For giggles also include CSS files
      $('link[rel=stylesheet]').each (i, a) ->
        $el = $(@)
        innerDeferred = Q.defer()
        promises.push innerDeferred.promise
        resourceRenamer $el.attr('href'), 'text/css', (err, newHref) ->
          href = $el.attr('href')
          if href != newHref
            newHrefs[href] = newHref
            task.work "Changing CSS from #{href} to #{newHref}"
            $el.attr('href', newHref)
          innerDeferred.resolve newHref

      # Remove the base tag
      $('head > base[href]').remove()

      task.work 'Done cleaning'
    catch error
      console.log 'cleanupHTML ERROR:'
      console.log error
      task.fail error
      errors = error

    # If an error occurred then call the callback with the errors
    if errors
      callback(errors)
    else
      # Once all the images and links are converted this cleanup is done
      Q.all(promises)
      .then ->
        newHtml = window.document.outerHTML
        newHtml = newHtml.replace(/&nbsp;/g, '&#160;')
        callback(errors, newHtml, newHrefs)
      .end()

# ### GET files from remote servers
# If a URL was provided in the deposit then pull in resources (images not links) it points to
module.exports.remoteGet = remoteGet = (remoteUrl, task, callback) ->
  getopts = url.parse(remoteUrl)
  task.work "Requesting remote resource #{ url.format(remoteUrl) }"

  protocol = if 'https:' == getopts.protocol then https else http
  protocol.get(getopts, (resp) -> # TODO: This needs more robust error handling, just trying to keep it from taking down the server.
    responsedata = []
    responseLen = 0
    resp.on('data', (chunk) ->
      responsedata.push(chunk)
      responseLen += chunk.length
      task.work "Getting Data from #{url.format(remoteUrl)} (#{chunk.length})"
    )
    resp.on('error', (e) ->
      task.fail e
      callback(e)
    )
    resp.on('end', ->
      if responsedata.length
        task.work 'Got the resource'
        buf = new Buffer(responseLen)
        pos = 0
        for chunk in responsedata
          chunk.copy(buf, pos)
          pos += chunk.length
        callback(null, buf, resp.statusCode)
      else
        task.fail "Resource Not Found"
        callback('Resource not found', 'Page not found', 404)
    )
  ).on('error', (e) ->
    task.fail e
    callback(e)
  )


# Used to add to the list of resources available
newResource = (content, contentType, originalURL) ->
  id = resources.length
  resources.push
    content: content
    contentType: contentType
    originalURL: originalURL
  id


# ## Navigation Classes
#
# These provide a way of navigating a zip or remote URLs and are used by `asyncDeposit()` and `cleanupHtml()`.
# Depends on `remoteGet()` and the `url` and `path` packages.
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
  constructor: (@task, @archiveZip, @basePath) ->
  getBase: () -> @basePath
  goInto: (href) ->
    # Local files in the zip can point to:
    # * other local files
    # * remote files (retrieved using `remoteGet()`)
    if url.parse(href).protocol
      new UrlContext(@task, url.parse(href))
    else
      new PathContext(@task, @archiveZip, path.normalize(path.join(path.dirname(@basePath), href)))
  getData: (callback) ->
    entry = @archiveZip.getEntry(@basePath)
    if entry
      # Try to get the data asynchronously since it uses native zlib
      # But if we get a bad CRC the async code throws an exception instead of returning the partial data
      # So, in that case, get the data synchronously (something is better than nothing?)
      data = entry.getData()
      callback(not data, data)
    else
      callback('Error: Could not find zip entry', "Error: Could not find zip entry #{@basePath}")

# Helper function that instantiates the correct context based on the href.
# *Note:* archiveZip could be null
makeContext = (promise, href, archiveZip) ->
  contentUrl = url.parse(href)
  if href[0] == '<'
    context = new SingleFileContext(promise, href)
  else if contentUrl.protocol
    context = new UrlContext(promise, contentUrl) # TODO: Split off the text after the last slash
  else if archiveZip
    # Verify the file exists in the zip
    if not archiveZip.getEntry(contentUrl.pathname)
      promise.fail "Uploaded zip file does not contain a file named #{contentUrl.pathname}"
    context = new PathContext(promise, archiveZip, contentUrl.pathname) # TODO: Split off the text after the last slash
  else
    promise.fail 'Specified href to content without providing a zip payload or a hostname to pull from'
    context = null
  return context

# ## Asynchronous Deposit
#
# This method converts the content so it all points to repository id's
# and errors otherwise.
#
# Given a mapping from published id's to local hrefs into the zip or other public URLs
# and an optional zip, perform the 'deposit' by:
#
# 1. Converting local links to published id's
# 2. Importing images and other resources (from the ZIP or remote URLs)
module.exports.asyncDeposit = (argv, hrefLookup, archiveZip=null) ->
  hrefLookup.each (href) ->
    id = hrefLookup.getId(href)
    # Log that we're doing something on this piece of content
    promise = hrefLookup.getPromise(href)
    context = makeContext(promise, href, archiveZip)
    # if context = null then don't bother continuing (already failed the promise)
    return if not context

    promise.work('Importing/Cleaning')

    deferred = Q.defer()
    idsPromise = []
    idsPromise.push deferred.promise

    # Convert absolute URLs and relative hrefs into relative hrefs to published content
    #
    # The out-of-scope variables it relies on to work are:
    #
    # * `context`    : for navigating through the zip or remote URLs
    # * `hrefLookup` : for knowing how to resolve other new content
    linkRenamer = (href, callback) ->
      # Links may contain '#id123' at the end of them. Split that off and retain it (TODO: Verify it later)
      [newHref, inPageId] = href.split('#')
      # If it's a local link don't change it.
      if newHref == ''
        callback(false, href)
      # Otherwise look it up in the mapping of all content just deposited so we
      # can rename the link to point to the published content
      else
        newHref = context.goInto(newHref).getBase()
        # If the href points to content being published (in hrefLookup) then
        # use the id to the published content
        if hrefLookup.has newHref
          newId = hrefLookup.getId(newHref)
          newHref = "#{newId}"
          newHref += '#' + inPageId if inPageId?
          callback(false, newHref)
        # If the href points to some other absolute URL then don't change the href
        else if url.parse(newHref).protocol
          callback(false, href)
        else
          callback(true)

    # This tool will "import" a resource (think image) pointed to by context/href (a remote URL or inside the Zip file)
    resourceRenamer = (href, contentType, callback) ->
      context.goInto(href).getData (err, content) ->
        if not err
          # "Import" the resource
          rid = newResource(content, contentType, context.goInto(href).getBase())
          callback(err, "/resource/#{rid}")
        else
          console.warn "Error depositing resource because of status=#{err} (Probably missing file)"
          # Fail at this point, but since test-ccap has missing images let it slide ...
          callback(err, "Problem loading resource")

    # Pull out the file from the zip, clean it up (renaming links and storing images)
    # and then save the file (promise.finish)
    context.getData (err, text, statusCode) ->
      if not err
        # Clean up the HTML (rename links and resources using `linkRenamer` and `resourceRenamer`)
        promise.work('Cleaning up the HTML')
        cleanupHTML text, promise, resourceRenamer, linkRenamer, (error, cleanHtml) ->
          if error
            promise.fail('Problem in cleanup. Maybe the file is invalid HTML or points to invalid links')
          else
            promise.work 'Cleaned up HTML.'
            promise.work "updateContent id=#{id}"
            promise.finish cleanHtml

          #TODO Request a PDF to be generated
      else
        promise.fail("couldn't get data for some reason")
