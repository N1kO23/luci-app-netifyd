'use strict';
'require view';
'require form';
'require rpc';
'require ui';

var callRcInit = rpc.declare({
	object: 'rc',
	method: 'init',
	params: [ 'name', 'action' ]
});

return view.extend({
	render: function() {
		var m, s, o, self = this;

		m = new form.Map('netifyd-luci', _('Netifyd Settings'),
			_('Configure how the background collector connects to netifyd and how much data it keeps. ' +
				'Save & Apply first, then use "Restart service" below so the collector picks up the new settings.'));

		s = m.section(form.NamedSection, 'main', 'netifyd-luci');
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enabled'),
			_('Enable the background collector service.'));
		o.rmempty = false;

		o = s.option(form.Value, 'socket_path', _('Socket path'),
			_('Path to netifyd\'s local JSON socket (the "listen_path" of a [socket] section in /etc/netifyd.conf).'));
		o.placeholder = '/var/run/netifyd/netifyd.sock';
		o.rmempty = false;

		o = s.option(form.Value, 'poll_interval', _('Poll interval (seconds)'),
			_('How often the collector rebuilds its snapshot for the UI.'));
		o.datatype = 'range(1,300)';
		o.rmempty = false;

		o = s.option(form.Value, 'idle_ttl', _('Idle flow TTL (seconds)'),
			_('Flows not updated within this time are dropped from the snapshot.'));
		o.datatype = 'range(10,86400)';
		o.rmempty = false;

		o = s.option(form.Value, 'max_flows', _('Max flows shown'),
			_('Upper bound on how many flows the UI requests at once.'));
		o.datatype = 'range(1,5000)';
		o.rmempty = false;

		return m.render().then(function(mapEl) {
			var status = E('span', { 'style': 'margin-left:1em' });

			mapEl.appendChild(E('div', { 'style': 'margin-top:1em' }, [
				E('button', {
					'type': 'button',
					'class': 'btn cbi-button-action',
					'click': ui.createHandlerFn(self, function() {
						status.textContent = '';

						return callRcInit('netifyd-luci', 'restart').then(function(ret) {
							if (ret)
								throw new Error(_('Command failed'));

							status.textContent = _('Service restarted.');
						}).catch(function(e) {
							ui.addNotification(null, E('p', _('Failed to restart netifyd-luci: %s').format(e.message)));
						});
					})
				}, [ _('Restart service') ]),
				status
			]));

			return mapEl;
		});
	}
});
