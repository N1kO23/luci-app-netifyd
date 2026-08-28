'use strict';
'require view';
'require rpc';
'require poll';
'require dom';

var callFlows = rpc.declare({
	object: 'luci.netifyd',
	method: 'flows',
	params: [ 'limit' ],
	expect: { '': {} }
});

var sortKey = 'bytes';
var sortDir = -1;
var filterText = '';
var tableWrap = null;

function fmtBytes(n) {
	n = +n || 0;

	var units = [ 'B', 'KB', 'MB', 'GB', 'TB' ], i = 0;

	while (n >= 1024 && i < units.length - 1) {
		n /= 1024;
		i++;
	}

	return (i === 0 ? n : n.toFixed(1)) + ' ' + units[i];
}

function fmtAge(seenAt) {
	var now = Math.floor(Date.now() / 1000);
	var age = Math.max(0, now - (+seenAt || now));

	if (age < 60) return age + 's';
	if (age < 3600) return Math.floor(age / 60) + 'm';
	return Math.floor(age / 3600) + 'h';
}

function bytesOf(flow) {
	return flow.total_bytes || ((flow.local_bytes || 0) + (flow.other_bytes || 0));
}

function sortFlows(flows) {
	return flows.slice().sort(function(a, b) {
		var av, bv;

		switch (sortKey) {
		case 'bytes':
			av = bytesOf(a); bv = bytesOf(b);
			break;
		case 'protocol':
			av = a.detected_protocol_name || ''; bv = b.detected_protocol_name || '';
			break;
		case 'application':
			av = a.detected_application_name || ''; bv = b.detected_application_name || '';
			break;
		case 'seen':
			av = a.seen_at || 0; bv = b.seen_at || 0;
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
		flow.local_ip, flow.other_ip, flow.detected_protocol_name,
		flow.detected_application_name, flow.host_server_name
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
			refresh();
		}
	}, label + suffix);
}

var currentFlows = [];

function renderTable() {
	var flows = sortFlows(currentFlows.filter(matchesFilter));

	var rows = flows.slice(0, 200).map(function(f) {
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, (f.local_ip || '-') + ':' + (f.local_port || '-')),
			E('td', { 'class': 'td' }, (f.other_ip || '-') + ':' + (f.other_port || '-')),
			E('td', { 'class': 'td' }, f.detected_protocol_name || '-'),
			E('td', { 'class': 'td' }, f.detected_application_name || '-'),
			E('td', { 'class': 'td' }, f.host_server_name || '-'),
			E('td', { 'class': 'td', 'style': 'text-align:right' }, fmtBytes(bytesOf(f))),
			E('td', { 'class': 'td', 'style': 'text-align:right' }, fmtAge(f.seen_at))
		]);
	});

	if (!rows.length) {
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'colspan': 7 }, _('No active flows'))
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
			sortableHeader(_('Last seen'), 'seen')
		])
	].concat(rows));
}

function refresh() {
	if (tableWrap)
		dom.content(tableWrap, renderTable());
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return callFlows(500);
	},

	render: function(data) {
		currentFlows = (data && data.flows) || [];
		tableWrap = E('div', {}, renderTable());

		var filterInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'style': 'width:100%;max-width:24em',
			'placeholder': _('Filter by IP, protocol, application…'),
			'input': function(ev) {
				filterText = ev.target.value;
				refresh();
			}
		});

		poll.add(function() {
			return callFlows(500).then(function(res) {
				currentFlows = (res && res.flows) || [];
				refresh();
			});
		});

		return E('div', {}, [
			E('div', { 'style': 'margin-bottom:.75em' }, [ filterInput ]),
			tableWrap
		]);
	}
});
