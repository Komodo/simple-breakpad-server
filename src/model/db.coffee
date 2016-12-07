config = require '../config'
Sequelize = require 'sequelize'

options = config.get 'database'
options.define = options.define || {}

defaultModelOptions =
  timestamps: yes
  underscored: yes

options.define = Object.assign(options.define, defaultModelOptions)

sequelize = new Sequelize(options.database, options.username,
                          options.password, options)

sequelize.query("CREATE VIRTUAL TABLE IF NOT EXISTS crashreports_search USING fts4(id, body)")

module.exports = sequelize

