EventEmitter = require('events').EventEmitter
jsdom = require('jsdom') # For HTML cleanup

module.exports.files = files = []
module.exports.events = events = []
module.exports.Task = class Task extends EventEmitter
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


module.exports.cleanupHTML = cleanupHTML = (html, task, callback) ->
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



http = require('http')
https = require('https')
url = require('url')

module.exports.remoteGet = remoteGet = (remoteUrl, task, cb) ->
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


# Used to add a PDF to the list of files available
newFile = (body) ->
  id = files.length
  # Wrapped in array because it's version 0
  files.push body
  id


spawn = require('child_process').spawn
module.exports.generatePDF = generatePDF = (argv, task, originUrl) ->
  task.work 'Getting remote resource for PDF'
  # Send the HTML to the PDF script
  pdf = spawn(argv.pdfgen, [ '--no-network', '--input=html', '--verbose', '--output=/dev/stdout', '/dev/stdin' ])
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
      id = newFile(pdfContent)
      fileUrl = "#{argv.u}/files/#{id}"
      task.finish 'PDF Done!', fileUrl
    else
      task.fail "PDF Failed. Exit Code: #{code}.\n#{task.message}"
