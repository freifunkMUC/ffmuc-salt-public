function preread(s) {
	var buf = '';
	s.on('upload', function (data, flags) {
		buf += data;
		if (buf.indexOf('\r\n\r\n') !== -1 || flags.last || buf.length > 8192) {
			s.off('upload');
			s.done();
		}
	});
}
export default { preread };
