EventEmitter = require('events').EventEmitter
jsdom = require('jsdom') # For HTML cleanup
Q = require('q') # Promises, Promises

module.exports.resources = resources = []
module.exports.events = events = []

module.exports.Promise = class Promise extends EventEmitter
  constructor: (prerequisite) ->
    events.push @
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
  update: (msg) ->
    if @status == 'FINISHED' or @status == 'FAILED'
      message = @history[@history.length-1]
      err = { event: @, message: "This event already completed with status #{@status} and message='#{message}'", newMessage: msg }
      console.log err
      throw err
    @modified = new Date()
    @history.push msg
    if @history.length > 50
      @history.splice(0,1)
    @emit('update', msg)

  work: (message, @status='WORKING') ->
    @update(message)
    @emit('work')
  wait: (message, @status='PAUSED') ->
    @update(message)
    @emit('work')

  fail: (msg) ->
    @update msg
    @isProcessing = false
    @status = 'FAILED'
    @data = null
    @emit('fail')
  finish: (@data, @mimeType='text/html; charset=utf-8') ->
    @update "Generated file"
    @isProcessing = false
    @status = 'FINISHED'
    @emit('finish', @data, @mimeType)



module.exports.cleanupHTML = cleanupHTML = (argv, html, task, resourceRenamer, linkRenamer) ->
  deferred = Q.defer()
  task.work 'Cleaning up HTML. Parsing...'
  doc = jsdom.jsdom(html, null, 
    features:
      FetchExternalResources: false # ['img']
      ProcessExternalResources: false
  )
  window = doc.createWindow()
  if window.document and window.document.documentElement and window.document.body
    jsdom.jQueryify(window, "#{argv.u}/jquery-latest.js", (window, $) ->
      try
        task.work 'Starting clean'
        $ = window.jQuery
        $('script').remove()
        # $('head').remove() # TODO: look up attribution here
        $('*[style]').removeAttr('style')
        
        task.work 'Cleaning up links'
        promises = []
        $('a[href]').each (i, a) ->
          innerDeferred = Q.defer()
          promises.push innerDeferred.promise
          
          $el = $(@)
          linkRenamer $el.attr('href'), (err, newHref) ->
            if $el.attr('href') != newHref
              task.work "Changing link from #{$el.attr('href')} to #{newHref}"
              $el.attr('href', newHref)
            innerDeferred.resolve(newHref)
  
        $('img[src]').each (i, a) ->
          innerDeferred = Q.defer()
          promises.push innerDeferred.promise
          
          $el = $(@)
          resourceRenamer $el.attr('src'), 'image/jpeg', (err, newHref) ->
            if $el.attr('src') != newHref
              task.work "Changing resource from #{$el.attr('src')} to #{newHref}"
              $el.attr('src', newHref)
            innerDeferred.resolve(newHref)

        # For giggles also include CSS files
        $('link[rel=stylesheet]').each (i, a) ->
          innerDeferred = Q.defer()
          promises.push innerDeferred.promise
          
          $el = $(@)
          resourceRenamer $el.attr('href'), 'text/css', (err, newHref) ->
            if $el.attr('href') != newHref
              task.work "Changing resource from #{$el.attr('href')} to #{newHref}"
              $el.attr('href', newHref)
            innerDeferred.resolve(newHref)

        # Remove the base tag
        $('head > base[href]').each (i, a) ->
          $(@).remove()

        Q.all(promises)
        .then () ->
          newHtml = doc.outerHTML
          newHtml = newHtml.replace(/&nbsp;/g, '&#160;')
          deferred.resolve(doc.outerHTML)
        .end()
        task.work 'Done cleaning'
      catch error
        console.log 'cleanupHTML ERROR:'
        console.log error
        task.fail error
    )
  else
    # TODO: The following should be deferred.reject but it's set to "resolve" for the demo
    #task.fail "Could not generate window.document.body for this HTML"
    #deferred.reject(new Error("ERROR: This HTML file could not be parsed for some reason."))
    task.work "Could not generate window.document.body for this HTML"
    deferred.resolve "<html><body>ERROR: This HTML file could not be parsed for some reason.</body></html>"
  deferred.promise



http = require('http')
https = require('https')
url = require('url')

module.exports.remoteGet = remoteGet = (remoteUrl, task, callback) ->
  getopts = url.parse(remoteUrl)
  task.work "Requesting remote resource #{ url.format(remoteUrl) }"
  
  protocol = if 'https:' == getopts.protocol then https else http
  # TODO: This needs more robust error handling, just trying to
  # keep it from taking down the server.
  protocol.get(getopts, (resp) ->
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


# Used to add a PDF to the list of resources available
module.exports.newResource = newResource = (content, contentType, originalURL) ->
  id = resources.length
  # Wrapped in array because it's version 0
  resources.push
    content: content
    contentType: contentType
    originalURL: originalURL
  id


spawn = require('child_process').spawn
module.exports.generatePDF = generatePDF = (argv, task, originUrl) ->
  task.work 'Getting remote resource for PDF'
  # Send the HTML to the PDF script
  options =
    env: process.env
  pdf = spawn(argv.pdfgen, [ "--baseurl=#{argv.u}/content/", '--input=html', '--verbose', '--output=/dev/stdout', '/dev/stdin' ], options)
  remoteGet originUrl, task, (err, text, statusCode) -> 
    if text
      task.work "Got data. Writing to prince #{text.length} chars"
      pdf.stdin.write(text)
      pdf.stdin.end()
    else
      console.log("Error: pdf failing because no HTML was received")
      task.fail err
      pdf.exit()

  pdfChunks = []
  pdfChunksLen = 0
  pdf.stdout.on 'data', (data) ->
    pdfChunks.push data
    pdfChunksLen += data.length
  pdf.stderr.on 'data', (data) ->
    task.work "Warning: #{data}"
  
  pdf.on 'exit', (code) ->
    if 0 == code
      pdfContent = new Buffer(pdfChunksLen)
      pos = 0
      for chunk in pdfChunks
        chunk.copy(pdfContent, pos)
        pos += chunk.length
      id = newResource(pdfContent, 'application/pdf')
      fileUrl = "#{argv.u}/resource/#{id}"
      task.finish 'PDF Done!', fileUrl
    else
      task.fail "PDF Failed. Exit Code: #{code}.\n#{task.message}"
