module.exports =
	src: [
		'src'
	]
	out: 'out'
	plugins: [
		'node_modules'
		'plugins'
	]
	ignore: [
		///\.DS_Store$///
	]
	noprocess: [
		///\.verstat\.(coffee|js|yaml|yml|json)$///
	]
	nowrite: [
		///\.verstat\.(coffee|js|yaml|yml|json)$///
		///\.jade$///
		///\.less$///
		///\.styl$///
		///\.coffee$///
	]
	nocopy: [
		///\.verstat\.(coffee|js|yaml|yml|json)$///
	]
	rawExtnames: [
		'.png'
		'.jpg'
		'.gif'
		'.woff'
		'.svg'
		'.ttf'
		'.eot'
	]
	processExtnames: [
		'.css'
		'.js'
		'.html'
	]