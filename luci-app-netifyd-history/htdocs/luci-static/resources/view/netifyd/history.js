'use strict';
'require view';
'require rpc';
'require dom';

var callStatus = rpc.declare({
	object: 'luci.netifyd-history',
	method: 'status',
	expect: { '': {} }
});

var callSeries = rpc.declare({
	object: 'luci.netifyd-history',
	method: 'series',
	params: [ 'dimension', 'since', 'until' ],
	expect: { '': {} }
});

var callFlows = rpc.declare({
	object: 'luci.netifyd-history',
	method: 'flows',
	params: [ 'since', 'until', 'protocol', 'application', 'ip', 'limit', 'offset' ],
	expect: { '': {} }
});

var RANGES = [
	{ label: _('Last hour'), seconds: 3600 },
	{ label: _('Last 6 hours'), seconds: 21600 },
	{ label: _('Last 24 hours'), seconds: 86400 },
	{ label: _('Last 7 days'), seconds: 604800 }
];

function fmtBytes(n) {
	n = +n || 0;

	var units = [ 'B', 'KB', 'MB', 'GB', 'TB' ], i = 0;

	while (n >= 1024 && i < units.length - 1) {
		n /= 1024;
		i++;
	}

	return (i === 0 ? n : n.toFixed(1)) + ' ' + units[i];
}

function fmtDateTime(sec) {
	sec = +sec || 0;
	return sec ? new Date(sec * 1000).toLocaleString() : '-';
}

function fmtDuration(startSec, endSec) {
	var sec = Math.max(0, (+endSec || 0) - (+startSec || 0));

	if (sec < 60) return sec + 's';
	if (sec < 3600) return Math.floor(sec / 60) + 'm';
	return Math.floor(sec / 3600) + 'h ' + Math.floor((sec % 3600) / 60) + 'm';
}

function aggregateSeries(series) {
	var totals = {};

	(series || []).forEach(function(row) {
		var key = row.key || _('unknown');
		if (!totals[key])
			totals[key] = { key: key, bytes: 0, packets: 0, flows: 0 };
		totals[key].bytes += row.bytes || 0;
		totals[key].packets += row.packets || 0;
		totals[key].flows += row.flows || 0;
	});

	return Object.keys(totals).map(function(k) {
		return totals[k];
	}).sort(function(a, b) {
		return b.bytes - a.bytes;
	});
}

function breakdownTable(title, rows, totalBytes) {
	var body = [];

	if (!rows || !rows.length) {
		body.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, _('No data in this range'))
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

var rangeSeconds = 86400;
var sortKey = 'ended_at';
var sortDir = -1;
var filterText = '';
var currentFlows = [];
var flowsWrap = null;

function sortFlows(flows) {
	return flows.slice().sort(function(a, b) {
		var av, bv;

		switch (sortKey) {
		case 'bytes':
			av = a.total_bytes || 0; bv = b.total_bytes || 0;
			break;
		case 'protocol':
			av = a.protocol || ''; bv = b.protocol || '';
			break;
		case 'application':
			av = a.application || ''; bv = b.application || '';
			break;
		case 'ended_at':
			av = a.ended_at || 0; bv = b.ended_at || 0;
			break;
		default:
			av = 0; bv = 0;
		}

		if (av < bv) return -1 * sortDir;
		if (av > bv) return 1 * sortDir;
		return 0;
	});
}

function matchesFilter(flow) {
	if (!filterText)
		return true;

	var needle = filterText.toLowerCase();

	return [
		flow.local_ip, flow.other_ip, flow.protocol,
		flow.application, flow.host_server_name
	].some(function(v) {
		return (v || '').toLowerCase().indexOf(needle) !== -1;
	});
}

function sortableHeader(label, key) {
	var suffix = sortKey === key ? (sortDir === -1 ? ' ▼' : ' ▲') : '';

	return E('th', {
		'class': 'th',
		'style': 'cursor:pointer;white-space:nowrap',
		'click': function() {
			if (sortKey === key) sortDir *= -1;
			else { sortKey = key; sortDir = -1; }
			renderFlowsWrap();
		}
	}, label + suffix);
}

function renderFlowsTable() {
	var flows = sortFlows(currentFlows.filter(matchesFilter));

	var rows = flows.slice(0, 300).map(function(f) {
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, (f.local_ip || '-') + ':' + (f.local_port || '-')),
			E('td', { 'class': 'td' }, (f.other_ip || '-') + ':' + (f.other_port || '-')),
			E('td', { 'class': 'td' }, f.protocol || '-'),
			E('td', { 'class': 'td' }, f.application || '-'),
			E('td', { 'class': 'td' }, f.host_server_name || '-'),
			E('td', { 'class': 'td', 'style': 'text-align:right' }, fmtBytes(f.total_bytes)),
			E('td', { 'class': 'td' }, fmtDuration(f.started_at, f.ended_at)),
			E('td', { 'class': 'td' }, fmtDateTime(f.ended_at))
		]);
	});

	if (!rows.length) {
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'colspan': 8 }, _('No completed flows in this range'))
		]));
	}

	return E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Local')),
			E('th', { 'class': 'th' }, _('Remote')),
			sortableHeader(_('Protocol'), 'protocol'),
			sortableHeader(_('Application'), 'application'),
			E('th', { 'class': 'th' }, _('Server name')),
			sortableHeader(_('Traffic'), 'bytes'),
			E('th', { 'class': 'th' }, _('Duration')),
			sortableHeader(_('Ended'), 'ended_at')
		])
	].concat(rows));
}

function renderFlowsWrap() {
	if (flowsWrap)
		dom.content(flowsWrap, renderFlowsTable());
}

var rangeButtonsWrap = null;
var contentWrap = null;

function renderRangeButtons() {
	return E('div', { 'style': 'margin-bottom:1em' }, RANGES.map(function(r) {
		return E('button', {
			'class': 'btn' + (r.seconds === rangeSeconds ? ' cbi-button-action important' : ''),
			'style': 'margin-right:.5em',
			'click': function() {
				rangeSeconds = r.seconds;
				refresh();
			}
		}, [ r.label ]);
	}));
}

function refresh() {
	var now = Math.floor(Date.now() / 1000);
	var since = now - rangeSeconds;

	return Promise.all([
		callStatus(),
		callSeries('protocol', since, now),
		callSeries('application', since, now),
		callSeries('category', since, now),
		callFlows(since, now, '', '', '', 300, 0)
	]).then(function(data) {
		if (rangeButtonsWrap) dom.content(rangeButtonsWrap, renderRangeButtons());
		if (contentWrap) dom.content(contentWrap, renderContent(data));
	});
}

function renderContent(data) {
	var status = data[0] || {};
	var db = status.db || {};
	var collector = status.collector || {};

	if (!collector.db_path) {
		return [
			E('div', { 'class': 'alert-message notice' }, [
				E('p', {}, _('History logging is not set up yet: no database path is configured.')),
				E('p', {}, _('Set one from the command line, then restart the netifyd-history service, e.g.:')),
				E('pre', {}, 'uci set netifyd-luci-history.main.db_path=/mnt/usb/netifyd-history.db\n' +
					'uci set netifyd-luci-history.main.enabled=1\n' +
					'uci commit netifyd-luci-history\n' +
					'/etc/init.d/netifyd-history restart')
			])
		];
	}

	var protocolTotals = aggregateSeries(data[1] && data[1].series);
	var applicationTotals = aggregateSeries(data[2] && data[2].series);
	var categoryTotals = aggregateSeries(data[3] && data[3].series);
	var totalBytes = protocolTotals.reduce(function(n, r) { return n + r.bytes; }, 0);

	currentFlows = (data[4] && data[4].flows) || [];

	var nodes = [];

	if (db.flow_count === 0 || db.flow_count == null) {
		nodes.push(E('div', { 'class': 'alert-message notice' }, [
			E('p', {}, _('No history recorded yet. Data will appear here once flows complete while the netifyd-history service is running.'))
		]));
	}

	nodes.push(breakdownTable(_('By protocol'), protocolTotals, totalBytes));
	nodes.push(breakdownTable(_('By application'), applicationTotals, totalBytes));
	nodes.push(breakdownTable(_('By category'), categoryTotals, totalBytes));

	var filterInput = E('input', {
		'type': 'text',
		'class': 'cbi-input-text',
		'style': 'width:100%;max-width:24em',
		'placeholder': _('Filter by IP, protocol, application…'),
		'input': function(ev) {
			filterText = ev.target.value;
			renderFlowsWrap();
		}
	});

	flowsWrap = E('div', {}, renderFlowsTable());

	nodes.push(E('div', { 'class': 'cbi-section', 'style': 'margin-top:1em' }, [
		E('h3', {}, _('Completed flows')),
		E('div', { 'style': 'margin-bottom:.75em' }, [ filterInput ]),
		flowsWrap
	]));

	return nodes;
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		var now = Math.floor(Date.now() / 1000);
		var since = now - rangeSeconds;

		return Promise.all([
			callStatus(),
			callSeries('protocol', since, now),
			callSeries('application', since, now),
			callSeries('category', since, now),
			callFlows(since, now, '', '', '', 300, 0)
		]);
	},

	render: function(data) {
		rangeButtonsWrap = E('div', {}, renderRangeButtons());
		contentWrap = E('div', {}, renderContent(data));

		return E('div', {}, [ rangeButtonsWrap, contentWrap ]);
	}
});
