'use strict';
'require view';
'require rpc';
'require poll';
'require dom';

var callStatus = rpc.declare({
	object: 'luci.netifyd',
	method: 'status',
	expect: { '': {} }
});

var callOverview = rpc.declare({
	object: 'luci.netifyd',
	method: 'overview',
	expect: { '': {} }
});

function fmtBytes(n) {
	n = +n || 0;

	var units = [ 'B', 'KB', 'MB', 'GB', 'TB' ], i = 0;

	while (n >= 1024 && i < units.length - 1) {
		n /= 1024;
		i++;
	}

	return (i === 0 ? n : n.toFixed(1)) + ' ' + units[i];
}

function fmtUptime(sec) {
	sec = +sec || 0;

	var d = Math.floor(sec / 86400);
	var h = Math.floor((sec % 86400) / 3600);
	var m = Math.floor((sec % 3600) / 60);
	var parts = [];

	if (d) parts.push(d + 'd');
	if (h) parts.push(h + 'h');
	parts.push(m + 'm');

	return parts.join(' ');
}

function statCard(title, value) {
	return E('div', {
		'style': 'flex:1 1 200px;padding:.75em 1em;border:1px solid var(--border-color-medium,#ccc);border-radius:4px;'
	}, [
		E('div', { 'style': 'font-size:.85em;opacity:.75' }, title),
		E('div', { 'style': 'font-size:1.4em;font-weight:600' }, value)
	]);
}

function breakdownTable(title, rows, totalBytes) {
	var body = [];

	if (!rows || !rows.length) {
		body.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, _('No data yet'))
		]));
	} else {
		rows.slice(0, 10).forEach(function(row) {
			var pct = totalBytes > 0 ? (100 * row.bytes / totalBytes) : 0;

			body.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, row.key),
				E('td', { 'class': 'td', 'style': 'text-align:right' }, '%d'.format(row.flows)),
				E('td', { 'class': 'td' }, [
					E('div', {
						'class': 'cbi-progressbar',
						'title': '%s (%.1f%%)'.format(fmtBytes(row.bytes), pct)
					}, E('div', { 'style': 'width:%.1f%%'.format(pct) })),
					' ' + fmtBytes(row.bytes)
				])
			]));
		});
	}

	return E('div', { 'class': 'cbi-section', 'style': 'margin-top:1em' }, [
		E('h3', {}, title),
		E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Name')),
				E('th', { 'class': 'th', 'style': 'text-align:right' }, _('Flows')),
				E('th', { 'class': 'th' }, _('Traffic'))
			])
		].concat(body))
	]);
}

function renderContent(data) {
	var status = data[0] || {};
	var overview = data[1] || {};
	var agent = overview.agent || {};
	var nodes = [];

	if (!status.connected) {
		nodes.push(E('div', { 'class': 'alert-message warning' }, [
			E('p', {}, _('Not connected to netifyd: %s').format(status.message || _('unknown error'))),
			E('p', {}, _('Make sure netifyd is running with its local JSON socket enabled (add a [socket] section with a listen_path to /etc/netifyd.conf), then restart the netifyd-luci service on the Settings page.'))
		]));
	}

	nodes.push(E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:1em' }, [
		statCard(_('Active flows'), overview.flow_count || 0),
		statCard(_('Total traffic'), fmtBytes(overview.total_bytes)),
		statCard(_('Agent uptime'), agent.uptime ? fmtUptime(agent.uptime) : '-'),
		statCard(_('Agent version'), agent.agent_version || '-')
	]));

	nodes.push(breakdownTable(_('By protocol'), overview.by_protocol, overview.total_bytes));
	nodes.push(breakdownTable(_('By application'), overview.by_application, overview.total_bytes));
	nodes.push(breakdownTable(_('By category'), overview.by_category, overview.total_bytes));
	nodes.push(breakdownTable(_('Top talkers'), overview.top_talkers, overview.total_bytes));

	return nodes;
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return Promise.all([ callStatus(), callOverview() ]);
	},

	render: function(data) {
		var container = E('div', {}, renderContent(data));

		poll.add(function() {
			return Promise.all([ callStatus(), callOverview() ]).then(function(data) {
				dom.content(container, renderContent(data));
			});
		});

		return container;
	}
});
