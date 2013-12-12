EventEmitter = require('events').EventEmitter
fs = require "fs"
path = require "path"
mkdirp = require "mkdirp"
recursiveReaddir = require "recursive-readdir"
async = require "async"
rimraf = require "rimraf"
_ = require "lodash"
YAML = require "yamljs"
QueryEngine = require "query-engine"

module.exports = class Verstat extends EventEmitter
	constructor: (@env) ->
		super
		@config = {}
		@processors = {}
		@preprocessors = {}
		@postprocessors = {}
		@files = QueryEngine.createCollection []
		@plugins = {}
		@nextFileId = 1
		@log "INFO", "instantiated verstat with env #{env}"

		@on "templateData", (file, templateData) =>
			templateData = _.extend templateData, _.omit file, ['source', 'processed', 'fn', 'dependencies', 'dependants', 'read', 'process', 'write']
			templateData.env = @env
			templateData.queryFiles = (q) =>
				found = @files.findAll(q).toJSON()
				@depends file, found if found
				found
			templateData.queryFile = (q) =>
				found = @files.findOne(q).toJSON()
				@depends file, [ found ] if found
				found

	modified: (file) ->
		@files.remove(file.id).add(file)

	log: (level, objs...) ->
		level = level.toUpperCase()
		switch level
			when 'WARN', 'ERROR', 'FATAL'
				console.error level, objs...
			when 'INFO'
				console.log level, objs...
			# when 'DEBUG', 'TRACE'
			# 	console.log level, objs...

	generate: (next) ->
		if @config.out
			async.series [
				(cb) => rimraf @config.out, cb
				(cb) => @initPlugins cb
				(cb) => @readFiles cb
				(cb) => @processFiles cb
				(cb) => @writeFiles cb
			], next
		else
			next new Error "out must be configured"

	setupWatchr: (next) ->
		require('watchr').watch
			paths: @config.src
			# preferredMethods: ['watchFile', 'watch']
			listeners:
				log: (level, message) =>
					@log level, message
					if m = message.match ///^watch:\s*(.+)$///
						@emit "watchr:started", m[1]
				error: (err) =>
					@log "ERROR", "watchr error", err
				watching: (err, watcherInstance, isWatching) =>
					if err
						@log "ERROR", "watching failed", watcherInstance.path
					else
						@log "INFO", "watching started", watcherInstance.path
				change: (changeType, filePath, fileCurrentStat, filePreviousStat) =>
					@log "INFO", "watchr change", changeType, filePath
					@emit "watchr:change", changeType, filePath, fileCurrentStat, filePreviousStat
			next: (err, watchers) =>
				if err then @log "ERROR", "watchr failed", err
				else @log "INFO", "watchr ready"
				next err
		@on "watchr:change", (changeType, filePath) =>
			switch changeType
				when "create"
					if not fs.statSync(filePath).isDirectory()
						@buildFile filePath, (err, file) =>
							@emit "watchEvent", changeType, file
				when "update", "delete"
					file = @files.findOne(srcFilePath: filePath).toJSON()
					@emit "watchEvent", changeType, file

	watch: (next) ->
		@on "watchEvent", (changeType, file) =>
			switch changeType
				when "create", "update"
					async.series [
						(done) => @reworkFile file, done
						(done) => @reworkDependants file, done
					], (err) =>
						@log "ERROR", "error handling watchEvent", err if err
				when "delete"
					async.series [
						(done) => @removeFile file, done
						(done) => @reworkDependants file, done
					], (err) =>
						@log "ERROR", "error handling watchEvent", err if err

		@setupWatchr next

	reconfig: (newConfig, next) ->
		@config = newConfig
		@log "INFO", "reconfig", newConfig
		next()

	initPlugins: (next) ->
		@log "INFO", "initPlugins", @config.plugins
		async.each @config.plugins, (pluginsPath, donePluginsPath) =>
			@log "INFO", "initPlugins pluginsPath", pluginsPath
			fs.exists pluginsPath, (exists) =>
				if exists
					async.waterfall [
						(cb) => recursiveReaddir pluginsPath, cb
						(filePathList, cb) =>
							async.each filePathList, (filePath, doneFilePath) =>
								if filePath.match ///\.verstatplugin\.(coffee|js)///
									@initPlugin path.resolve(filePath), doneFilePath
								else
									doneFilePath null
							, cb
					], (err) =>
						donePluginsPath err
				else
					donePluginsPath()
		, next

	initPlugin: (pluginPath, next) ->
		@log "INFO", "initPlugin", pluginPath
		try
			plugin = require pluginPath
			plugin.bind(@) (err, data) =>
				if err then next err else
					@plugins[pluginPath] = data
					next null
		catch err
			next err

	processor: (name, processorConfig) ->
		@processors[name] = processorConfig
	preprocessor: (name, preprocessorConfig) ->
		@preprocessors[name] = preprocessorConfig
	postprocessor: (name, postprocessorConfig) ->
		@postprocessors[name] = postprocessorConfig

	resolveProcessor: (srcFilename) ->
		for name, processor of @processors
			return name if processor.srcExtname and processor.srcExtname is path.extname srcFilename
		return null

	readFiles: (next) ->
		@log "INFO", "readFiles", @config.src
		async.each @config.src, (srcPath, doneSrc) =>
			@log "INFO", "readFiles srcPath", srcPath
			async.waterfall [
				(cb) => recursiveReaddir srcPath, cb
				(filePathList, cb) =>
					async.each filePathList, (filePath, doneFilePath) =>
						async.waterfall [
							(builtFile) => @buildFile filePath, builtFile
							(file, fileRead) =>
								if file.read then @readFile file, fileRead else fileRead null, file
							(file, preprocessedFile) => @preprocessFile file, preprocessedFile
						], doneFilePath
					, cb
			], doneSrc
		, next

	resolveSrcPath: (filePath) ->
		for srcPath in @config.src
			return srcPath if filePath.indexOf srcPath is 0
		return null

	buildFile: (filePath, next) ->
		@log "INFO", "buildFile", filePath
		try
			srcPath = @resolveSrcPath filePath
			srcFilename = path.relative srcPath, filePath
			processor = @resolveProcessor srcFilename
			dir = path.dirname srcFilename
			dir = '' if dir is '.'
			filename = if processor
				processorConfig = @processors[processor]
				(if dir then dir + path.sep else '') + path.basename(srcFilename, processorConfig.srcExtname) + processorConfig.extname
			else
				srcFilename

			basename = path.basename filename
			extname = path.extname filename
			shortname = path.basename basename, extname

			@files.add file =
				id: "c#{@nextFileId++}"
				srcFilePath: filePath
				srcFilename: srcFilename
				srcExtname: path.extname srcFilename
				filename: filename
				dir: dir
				basename: basename
				extname: extname
				shortname: shortname
				fullname: (if dir then dir + path.sep else '') + shortname
				processor: processor
				read: on
				process: on
				write: on
				dependants: []
				dependencies: []

			next null, file
		catch err
			next err

	splitSourceAndMeta: (file, data, next) ->
		@log "INFO", "splitSourceAndMeta", file.id, file.srcFilePath
		switch file.srcExtname
			when ".jade"
				if data.match ///^//---\n///
					lines = data.split "\n"
					lines.splice 0, 1 # drop //---
					metaString = []
					while m = lines[0].match ///^\t(.*)$///
						metaString += m[1] + "\n"
						lines.splice 0, 1
					file.source = lines.join "\n"
					try
						_.extend file, YAML.parse metaString.replace ///\t///g, '  '
						next()
					catch e
						next e
				else
					file.source = data
					next()
			when ".json"
				file.source = data
				try
					_.extend file, JSON.parse data
					next()
				catch e
					next e
			when ".yaml", ".yml"
				file.source = data
				try
					_.extend file, YAML.parse data
					next()
				catch e
					next e
			else
				if m = data.match ///^---\n///
					lines = data.split "\n"
					lines.splice 0, 1 # drop first ---
					metaString = []
					while lines[0] isnt '---'
						metaString += lines[0] + "\n"
						lines.splice 0, 1
					lines.splice 0, 1 # drop last ---

					file.source = lines.join "\n"
					try
						_.extend file, YAML.parse metaString.replace ///\t///g, '  '
						next()
					catch e
						next e
				else
					file.source = data
					next()

	readFile: (file, next) ->
		@log "INFO", "readFile", file.srcFilePath
		fs.readFile file.srcFilePath, encoding: 'utf8', (err, data) =>
			if err then next err else
				@splitSourceAndMeta file, data, (err) =>
					@modified file
					if err then next err else
						@emit "readFile", file
						next null, file

	preprocessFile: (file, next) ->
		preprocessors = _.filter @preprocessors, (c) ->
			_.has(c, 'extname') and file.extname is c.extname or _.has(c, 'srcExtname') and file.srcExtname is c.srcExtname or not _.has(c, 'extname') and not _.has(c, 'srcExtname')
		preprocessors = _.sortBy preprocessors, 'priority'

		async.eachSeries preprocessors, (preprocessor, nextPreprocessor) =>
			preprocessor.preprocess file, nextPreprocessor
		, next

	postprocessFile: (file, next) ->
		postprocessors = _.sortBy _.filter @postprocessors, (c, name) ->
			_.has(c, 'extname') and file.extname is c.extname or _.has(c, 'srcExtname') and file.srcExtname is c.srcExtname or not _.has(c, 'extname') and not _.has(c, 'srcExtname')
		postprocessors = _.sortBy postprocessors, 'priority'

		async.eachSeries postprocessors, (postprocessor, nextPostprocessor) =>
			postprocessor.postprocess file, nextPostprocessor
		, next

	processFiles: (next) ->
		@log "INFO", "processFiles"
		async.series [
			(processedFiles) =>
				async.each @files.findAll(process: on).toJSON(), (file, doneFile) =>
					@processFile file, doneFile
				, processedFiles
			(postprocessedFiles) =>
				async.each @files.toJSON(), (file, doneFile) =>
					@postprocessFile file, doneFile
				, postprocessedFiles
		], next
	
	processFile: (file, next) ->
		@log "INFO", "processFile", file.srcFilePath, file.processor
		if file.processor
			processor = @processors[file.processor]
			compilerOpts = {}
			processor.compile file, compilerOpts, (err, output) =>
				if err then next err else
					file.processed = output
					@modified file
					@emit "processFile", file
					next null, file
		else
			next null, file

	writeFiles: (next) ->
		@log "INFO", "writeFiles"
		async.each @files.findAll(write: on).toJSON(), (file, doneFile) =>
			@writeFile file, doneFile
		, next

	writeFile: (file, next) ->
		@log "INFO", "writeFile", file.srcFilePath, file.filename
		mkdirp path.dirname("#{@config.out}/#{file.filename}"), (err) =>
			if err
				@log "ERROR", "error creating directories", err
			else
				data = if file.processor then file.processed else file.source
				fs.writeFile "#{@config.out}/#{file.filename}", data, encoding: 'utf8', next

	reworkFile: (file, next) ->
		@log "INFO", "reworkFile", file.id, file.srcFilePath
		async.series [
			(cb) => if file.read then @readFile file, cb else cb()
			(cb) => @preprocessFile file, cb
			(cb) => if file.process then @processFile file, cb else cb()
			(cb) => @postprocessFile file, cb
			(cb) => if file.write then @writeFile file, cb else cb()
		], next

	reworkDependants: (file, next) ->
		@log "INFO", "reworkDependants", file.id, file.srcFilePath, file.dependants
		async.each file.dependants, (id, doneDependant) =>
			dependantFile = @files.findOne(id: id).toJSON()
			if dependantFile
				@reworkFile dependantFile, doneDependant
			else doneDependant()
		, next

	removeFile: (file, next) ->
		fs.unlink "#{@config.out}/#{file.filename}", (err) =>
			@files.remove file.id

	depends: (file, dependencies) ->
		for dependency in dependencies
			file.dependencies.push dependency.id if dependency.id not in file.dependencies
			dependency.dependants.push file.id if file.id not in dependency.dependants
			@modified dependency
		@modified file

	serve: (port, next) ->
		express = require 'express'
		app = express()
		app.set "port", port
		app.use express.logger @env
		app.use express.static @config.out
		app.use express.errorHandler()
		
		if @env is 'dev'
			@watch => @log "INFO", "watch started"
			
			livereload = require 'livereload'
			livereload.createServer
				exts: ['html', 'js', 'css', 'png', 'jpg', 'gif']
				applyCSSLive: on
				applyJSLive: off
			.watch @config.out
		
		http = require 'http'
		http.createServer(app).listen app.get('port'), =>
			@log "INFO", "server started on port #{port}"
			next()

		# console.log require('util').inspect @files.toJSON(), colors: on
