config = require '../config'
path = require 'path'
fs = require 'fs-promise'
cache = require './cache'
minidump = require 'minidump'
Sequelize = require 'sequelize'
sequelize = require './db'
tmp = require 'tmp'

symbolsPath = config.getSymbolsPath()

# custom fields should have 'files' and 'params'
customFields = config.get('customFields') || {}

schema =
  id:
    type: Sequelize.INTEGER
    autoIncrement: yes
    primaryKey: yes
  product: Sequelize.STRING
  version: Sequelize.STRING
  Platform: Sequelize.STRING
  PlatformVersion: Sequelize.STRING
  Reason: Sequelize.STRING
  StackStart: Sequelize.STRING
  Contacted: Sequelize.INTEGER
  upload_file_minidump: Sequelize.BLOB


options =
  indexes: [
    { fields: ['created_at'] },
    { fields: ['Comments'] },
    { fields: ['id', 'Comments'] }
  ]

for field in (customFields.params || [])
  schema[field] = Sequelize.STRING

for field in (customFields.files || [])
  schema[field] = Sequelize.BLOB

Crashreport = sequelize.define('crashreports', schema, options)

Crashreport.getStackTrace = (record, callback) ->
  return callback(null, cache.get(record.id)) if cache.has record.id

  tmpfile = tmp.fileSync()
  fs.writeFile(tmpfile.name, record.upload_file_minidump).then ->
    minidump.walkStack tmpfile.name, [symbolsPath], (err, report) ->
      tmpfile.removeCallback()
      cache.set record.id, report unless err?
      callback err, report
  .catch (err) ->
    tmpfile.removeCallback()
    callback err

Crashreport.getStackTraceRaw = (data, callback) ->
  tmpfile = tmp.fileSync()
  fs.writeFile(tmpfile.name, data).then ->
    minidump.walkStack tmpfile.name, [symbolsPath], (err, report) ->
      tmpfile.removeCallback()
      callback err, report
  .catch (err) ->
    tmpfile.removeCallback()
    callback err

module.exports = Crashreport
