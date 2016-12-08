config = require './config'
moment = require 'moment'
bodyParser = require 'body-parser'
methodOverride = require('method-override')
path = require 'path'
express = require 'express'
exphbs = require 'express-handlebars'
hbsPaginate = require 'handlebars-paginate'
paginate = require 'express-paginate'
Crashreport = require './model/crashreport'
db = require './model/db'
titleCase = require 'title-case'
busboy = require 'connect-busboy'
streamToArray = require 'stream-to-array'
Sequelize = require 'sequelize'
request = require 'request'
#https = require 'https'
#fs = require 'fs'
ipfilter = require('express-ipfilter').IpFilter
fs = require 'fs-promise'
SqlString = require 'sqlstring'
nodemailer = require 'nodemailer'

bugsnagReport = (props, stack) ->

  summary = props.FramePoisonBase + " :: " + props.PyxpcomMethod
  if props.StackStart
    summary = props.StackStart

  exceptions = []
  exceptions.push({errorClass: props.Reason || "Crash", message: summary, stacktrace: []})

  if props.StackStart
    thread0 = stack.match(/Thread 0([\s\S]*?)Thread 1/)
    if (thread0)
      bits = thread0[1].split(/\s\d+\s\s/)

      for x of bits
        bit = bits[x]
        exceptions[0].stacktrace.push({ file: bit.split("\n")[0], lineNumber: 0, columnNumber: 0, method: "", code: bit })

  payload = {
    apiKey: config.get('bugsnagApiKey'),
    notifier: {
      name: "Komodo-Crash",
      version: "1.0"
    },
    events: [{
        payloadVersion: "2",
        context: summary,
        app: {
          type: props.product,
          version: props.version,
          build: props.BuildID,
          releaseStage: props.Platform + " - " + props.ReleaseChannel
        },
        device: {
          platform: props.Platform || "Unknown",
          release: props.PlatformVersion || ""
        },
        metaData: {
          state: {
            Notes: props.Notes
            InstallTime: props.InstallTime
            StartupTime: props.StartupTime
            CrashTime: props.CrashTime
            SecondsSinceLastCrash: props.SecondsSinceLastCrash
            AdapterVendorID: props.AdapterVendorID
            AdapterDeviceID: props.AdapterDeviceID
            AdapterDrive: props.AdapterDrive
            FramePoisonBase: props.FramePoisonBase
            FramePoisonSize: props.FramePoisonSize
            PyxpcomMethod: props.PyxpcomMethod
            Comments: props.Comments
          }
        },
        exceptions: exceptions,
        user: {
          email: props.Email || ""
        }
      }
    ]
  }

  opts = {
    method: "post",
    url: "https://notify.bugsnag.com",
    json: true,
    body: payload
  }
  request opts, (err, httpResponse, body) ->
    if (err)
      console.log(err)
    else
      console.log("Bugsnag Notified")
      console.log(body)


crashreportToApiJson = (crashreport) ->
  json = crashreport.toJSON()

  for k,v of json
    if Buffer.isBuffer(json[k])
      json[k] = "/crashreports/#{json.id}/files/#{k}"

  json

crashreportToViewJson = (report, limited) ->
  hidden = ['id', 'updated_at']
  shown = config.get('customFields').listedParams
  fields =
    id: report.id
    props: {}

  for name, value of Crashreport.attributes
    if value.type instanceof Sequelize.BLOB and not limited
      fields.props[name] = { path: "/crashreports/#{report.id}/files/#{name}" }

  json = report.toJSON()
  for k,v of json
    if k in hidden
      # pass
    else if Buffer.isBuffer(json[k])
      # already handled
    else if k == 'created_at' and not limited
      # change the name of this key for display purposes
      fields.props['created'] = moment(v).fromNow()
    else if v instanceof Date and not limited
      fields.props[k] = moment(v).fromNow()
    else
      if limited
        if k in shown
          fields.props[k] = if v? then v else 'not present'
      else
        fields.props[k] = if v? then v else 'not present'

  return fields

# initialization: init db and write all symfiles to disk
db.sync()
  .then ->
    run()
  .catch (err) ->
    console.error err.stack
    process.exit 1

run = ->
  app = express()
  breakpad = express()

  app.use(ipfilter(config.get("ipWhitelist"), {mode: 'allow', excluding: ['/crashreports/submit'], allowedHeaders: [] }))

  hbs = exphbs.create
    defaultLayout: 'main'
    partialsDir: path.resolve(__dirname, '..', 'views')
    layoutsDir: path.resolve(__dirname, '..', 'views', 'layouts')
    helpers:
      paginate: hbsPaginate
      reportUrl: (id) -> "/crashreports/#{id}"
      titleCase: titleCase

  breakpad.set 'json spaces', 2
  breakpad.set 'views', path.resolve(__dirname, '..', 'views')
  breakpad.engine('handlebars', hbs.engine)
  breakpad.set 'view engine', 'handlebars'
  breakpad.use bodyParser.json()
  breakpad.use bodyParser.urlencoded({extended: true})
  breakpad.use methodOverride()

  baseUrl = config.get('baseUrl')
  port = config.get('port')

  app.use baseUrl, breakpad

  bsStatic = path.resolve(__dirname, '..', 'node_modules/bootstrap/dist')
  breakpad.use '/assets', express.static(bsStatic)

  # error handler
  app.use (err, req, res, next) ->
    if not err.message?
      console.log 'warning: error thrown without a message'

    console.trace err
    res.status(500).send "Bad things happened:<br/> #{err.message || err}"

  breakpad.use(busboy())
  breakpad.post '/crashreports/submit', (req, res, next) ->
    props = {}
    streamOps = []

    req.busboy.on 'file', (fieldname, file, filename, encoding, mimetype) ->
      streamOps.push streamToArray(file).then((parts) ->
        buffers = []
        for i in [0 .. parts.length - 1]
          part = parts[i]
          buffers.push if part instanceof Buffer then part else new Buffer(part)

        return Buffer.concat(buffers)
      ).then (buffer) ->
        if fieldname of Crashreport.attributes
          props[fieldname] = buffer

    req.busboy.on 'field', (fieldname, val, fieldnameTruncated, valTruncated) ->
      if fieldname == 'ProductName'
        props['product'] = val
      else if fieldname == 'Version'
        props['version'] = val
      else if fieldname of Crashreport.attributes
        props[fieldname] = val.toString()

    req.busboy.on 'finish', ->
      Promise.all(streamOps).then ->

        Crashreport.getStackTraceRaw props.upload_file_minidump, (err, stackwalk) ->
          return next err if err?

          stackwalk = stackwalk.toString('utf8')
          dump = stackwalk.substr(0,500)
          
          platform = dump.match(/Operating system:\s([\s\S]*?)\s[A-Z]+:/)
          if (platform)
            [platform, version] = platform[1].split("\n")
            props.Platform = platform.trim()
            props.PlatformVersion = version.trim()

          reason = dump.match(/Crash reason:\s+(.*?)\n/)
          if (reason)
            props.Reason = reason[1]

          stackStart = dump.match(/Thread .*?\n[\s\d]+(.*?)\n/)
          if (stackStart)
            props.StackStart = stackStart[1]
              
          bugsnagReport props, stackwalk
  
          Crashreport.create(props).then (report) ->
            json = report.toJSON()
            data = []
            fields = ['product', 'version', 'Platform', 'PlatformVersion', 'Reason', 'StackStart', 'ProductID', 'BuildID', 'ReleaseChannel', 'Notes', 'AdapterVendorID', 'AdapterDeviceID', 'FramePoisonBase', 'FramePoisonSize', 'PyxpcomMethod', 'Email', 'Comments']
            for field in fields
              data.push props[field] || ""
            db.query("INSERT INTO crashreports_search VALUES (?, ?)", { replacements: [report.id, data.join(" | ")] })
            res.json(crashreportToApiJson(report))
            
      .catch (err) ->
        next err

    req.pipe(req.busboy)

  breakpad.get '/', (req, res, next) ->
    res.redirect '/crashreports'

  breakpad.use paginate.middleware(10, 50)
  breakpad.get '/crashreports', (req, res, next) ->
    limit = req.query.limit
    offset = req.offset
    page = req.query.page

    attributes = []

    # only fetch non-blob attributes to speed up the query
    for name, value of Crashreport.attributes
      unless value.type instanceof Sequelize.BLOB
        attributes.push name

    findAllQuery =
      order: 'created_at DESC'
      limit: limit
      offset: offset
      attributes: attributes
      
    handleResults = (q) ->
      records = q.rows
      count = q.count
        
      pageCount = Math.ceil(count / limit)

      viewReports = []
      for x of records
        viewReports.push(crashreportToViewJson(records[x], true))

      fields =
        if viewReports.length
          Object.keys(viewReports[0].props)
        else
          []
          
      pageStart = page - 5
      if pageStart < 1
        pageStart = 1
        
      pageEnd = pageStart + 10
      if pageEnd > pageCount
        pageEnd = pageCount
      
      pageNumbers = []
      pageNumber = pageStart
      while pageNumber <= pageEnd
        pageNumbers.push {number: pageNumber, active: pageNumber == page}
        pageNumber++

      res.render 'crashreport-index',
        title: 'Crash Reports'
        crashreportsActive: yes
        records: viewReports
        fields: fields
        req: req
        pagination:
          hide: pageCount <= 1
          page: page
          pageNext: page+1
          pagePrev: page-1
          pageCount: pageCount
          pageNumbers: pageNumbers
          pageStart: pageStart
          pageEnd: pageEnd
    
    if (req.query.s or req.query.c)
      findAllQuery.where = {}
    
    if req.query.s
      findAllQuery.where.id = {
        $in: db.literal(
          "(SELECT id FROM crashreports_search WHERE body MATCH "+SqlString.escape(req.query.s)+")"
        )
      }
      
    if req.query.c
      findAllQuery.where.Comments = {
        $ne: null
      }
  
    Crashreport.findAndCountAll(findAllQuery).then handleResults

  breakpad.use paginate.middleware(10, 50)

  breakpad.get '/crashreports/:id', (req, res, next) ->
    Crashreport.findById(req.params.id).then (report) ->
      if not report?
        return res.send 404, 'Crash report not found'
      Crashreport.getStackTrace report, (err, stackwalk) ->
        return next err if err?
        fields = crashreportToViewJson(report).props
        
        fields["Add-ons"] = fields["Add-ons"].replace(/,/g, ", ")
        fields["Add-ons"] = fields["Add-ons"].replace(/%40/g, "@")
        
        fields["InstallTime"] = new Date(parseInt(fields["InstallTime"]) * 1000)
        fields["StartupTime"] = new Date(parseInt(fields["StartupTime"]) * 1000)
        fields["CrashTime"] = new Date(parseInt(fields["CrashTime"]) * 1000)

        res.render 'crashreport-view', {
          title: 'Crash Report'
          stackwalk: stackwalk
          product: fields.product
          version: fields.version
          Email: if fields.Email == "not present" then "" else fields.Email
          Comments: if fields.Comments == "not present" then "" else "> " + fields.Comments.replace(/\n/g, "\n> ")
          emailTemplate: config.get("email").template
          fields: fields
          id: req.params.id
        }
        
  breakpad.post '/crashreports/:id/email', (req, res, next) ->
    Crashreport.findById(req.params.id).then (report) ->
      if not report?
        return res.send 404, 'Crash report not found'
      
      fields = crashreportToViewJson(report).props
      
      transporter = nodemailer.createTransport(config.get("email").transport)
      opts = {
        from: config.get("email").from
        to: fields.Email
        subject: req.body.subject
        text: req.body.message
      }
      
      transporter.sendMail opts, (error, info) ->
        if error
          res.render 'confirmation',
            title: 'Error'
            message: 'Error: ' + error
          return console.log error
        
        res.render 'confirmation',
          title: 'Message sent'
          message: 'Message sent: ' + info.response
        
        console.log 'Message sent: ' + info.response

  breakpad.get '/crashreports/:id/stackwalk', (req, res, next) ->
    # give the raw stackwalk
    Crashreport.findById(req.params.id).then (report) ->
      if not report?
        return res.send 404, 'Crash report not found'
      Crashreport.getStackTrace report, (err, stackwalk) ->
        return next err if err?
        res.set('Content-Type', 'text/plain')
        res.send(stackwalk.toString('utf8'))

  breakpad.get '/crashreports/:id/files/:filefield', (req, res, next) ->
    # download the file for the given id
    Crashreport.findById(req.params.id).then (crashreport) ->
      if not crashreport?
        return res.status(404).send 'Crash report not found'

      contents = crashreport.get(req.params.filefield)

      if not Buffer.isBuffer(contents)
        return res.status(404).send 'Crash report field is not a file'

      res.send(contents)

  breakpad.use(busboy())
  breakpad.post '/symfiles', (req, res, next) ->
    props = {}
    streamOps = []
    symbolsPath = config.getSymbolsPath()
    
    req.busboy.on 'file', (fieldname, file, filename, encoding, mimetype) ->
      streamOps.push streamToArray(file).then((parts) ->
        buffers = []
        for i in [0 .. parts.length - 1]
          part = parts[i]
          buffers.push if part instanceof Buffer then part else new Buffer(part)
  
        return Buffer.concat(buffers)
      ).then (buffer) ->
        if fieldname == 'symfile'
          props[fieldname] = buffer.toString()
  
    req.busboy.on 'finish', ->
      Promise.all(streamOps).then ->
        if not 'symfile' of props
          res.status 400
          throw new Error 'Form must include a "symfile" field'
  
        contents = props.symfile
        header = contents.split('\n')[0].split(/\s+/)
  
        [dec, os, arch, code, name] = header
  
        if dec != 'MODULE'
          msg = 'Could not parse header (expecting MODULE as first line)'
          throw new Error msg
        
        symfileDir = path.join(symbolsPath, name, code)
        fs.mkdirs(symfileDir).then ->
          filePath = path.join(symfileDir, "#{name}.sym")
          fs.writeFile(filePath, contents)
          
        res.json({name: name, dec: dec, os: os, arch: arch, code: code})
  
      .catch (err) ->
        console.log err
  
    req.pipe(req.busboy)

  #options = {
  #  key: fs.readFileSync(config.get('sslKeyFile')),
  #  cert: fs.readFileSync(config.get('sslCertFile'))
  #}
  #https.createServer(options, app).listen(port)
  app.listen(port)
  console.log "Listening on port #{port}"
