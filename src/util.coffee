EventEmitter = require('events').EventEmitter
jsdom = require('jsdom') # For HTML cleanup
Q = require('q') # Promises, Promises

module.exports.resources = resources = []
module.exports.events = events = []
module.exports.Task = class Task extends EventEmitter
  constructor: (@title, @origin) ->
    @history = [] # Stores all the changes made to the event
    @status = 'PENDING'
    @created = @modified = new Date()
    # Push it into the array so admin can keep track of it
    events.push @
    @id = events.length - 1

  _update: (message, status) ->
    if @status == 'FINISHED' or @status == 'FAILED'
      err = { event: @, message: "This event already completed with status #{@status} and message='#{@message}'", newMessage: message, newStatus: status }
      console.log err
      throw err
    @message = message
    @modified = new Date()
    @status = status
    @history.push(message)
    console.log "Event(#{@id}): #{@status} #{@message}"
  
  work: (message, status = 'WORKING') ->
    @_update(message, status)
    @emit('work')

  wait: (message, status = 'PAUSED') ->
    @_update(message, status)
    @emit('work')

  fail: (error) ->
    #error = JSON.stringify(error) if not typeof error = 'string'
    @_update(error, 'FAILED')
    @emit('error', 'FAILED')
  
  finish: (message, url) ->
    @_update(message, 'FINISHED')
    @url = url
    @emit('success', 'FINISHED')


module.exports.cleanupHTML = cleanupHTML = (argv, html, task, resourceRenamer, linkRenamer) ->
  deferred = Q.defer()
  task.work 'Cleaning up HTML. Parsing...'
  doc = jsdom.jsdom(html, null, 
    features:
      FetchExternalResources: false # ['img']
      ProcessExternalResources: false
  )
  window = doc.createWindow()
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
        resourceRenamer $el.attr('src'), (err, newHref) ->
          if $el.attr('src') != newHref
            task.work "Changing resource from #{$el.attr('src')} to #{newHref}"
            $el.attr('src', newHref)
          innerDeferred.resolve(newHref)
      Q.all(promises).then () ->
        deferred.resolve(doc.outerHTML)
      task.work 'Done cleaning'
    catch error
      console.log 'cleanupHTML ERROR:'
      console.log error
      task.fail error
  )
  deferred.promise



http = require('http')
https = require('https')
url = require('url')

module.exports.remoteGet = remoteGet = (remoteUrl, task, callback) ->
  getopts = url.parse(remoteUrl)
  task.work "Requesting remote resource #{ url.format(remoteUrl) }"
  task.url = remoteUrl
  
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
  pdf = spawn(argv.pdfgen, [ '--no-network', '--input=html', '--verbose', '--output=/dev/stdout', '/dev/stdin' ], options)
  remoteGet originUrl, task, (err, text, statusCode) -> 
    if text
      task.work "Got data. Writing to prince #{text.length} chars"
      pdf.stdin.write(text)
      pdf.stdin.end()
    else
      console.log("Error: pdf failing because no HTML was received")
      task.fail err
      pdf.exit()

  pdfContent = ''
  pdf.stdout.on 'data', (data) ->
    pdfContent += data
  pdf.stderr.on 'data', (data) ->
    task.work "Warning: #{data}"
  
  pdf.on 'exit', (code) ->
    if 0 == code
      id = newResource(pdfContent, 'application/pdf')
      fileUrl = "#{argv.u}/resource/#{id}"
      task.finish 'PDF Done!', fileUrl
    else
      task.fail "PDF Failed. Exit Code: #{code}.\n#{task.message}"
