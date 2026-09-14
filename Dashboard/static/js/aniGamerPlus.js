var dataArrays; //用户配置json
var proxy_protocol;
var proxy_ip;
var proxy_port;
var proxy_user = '';
var proxy_passwd = '';
id_list.push('proxy_protocol', 'proxy_ip', 'proxy_port', 'proxy_user', 'proxy_passwd');
id_list.push('browser_fingerprint_ja3', 'browser_fingerprint_akamai');

$.ajax({
	type: "get",
	url: "data/config.json",
	dataType: "json",
	async: true,
	success: function(data) {
		dataArrays = data;
		parseProxy(data.proxy);
		$(function (){
			renderJson();
		});
	}
});

showSnList();

// scheme://[使用者[:密碼]@]主機[:埠] —— 每一段都可能不在.
//
// 這支函式是在讀 config.json 的 callback 裡跑的, 所以它一旦丟出例外,
// renderJson() 就永遠不會執行: 整張設定表單會停在 HTML 的預設值上, 而使用者
// 按下保存時 readSettings() 讀到的就是那些預設值, 一次點擊把 config.json 蓋掉.
// 舊版直接對 regex 的結果取 [0], 少一段 (例如 "http://:" 這種沒有埠號的) 就是
// 一個 TypeError, 所以這裡改成純字串切割, 任何輸入都要有辦法收場.
function parseProxy(proxy) {
	var rest = (typeof proxy === 'string' ? proxy : '').trim();
	var protocol = '';
	var schemeEnd = rest.indexOf('://');
	if (schemeEnd >= 0) {
		protocol = rest.slice(0, schemeEnd);
		rest = rest.slice(schemeEnd + 3);
	}

	var user = '';
	var passwd = '';
	// 密碼本身可能含有 '@', 所以要切最後一個, 不是第一個
	var at = rest.lastIndexOf('@');
	if (at >= 0) {
		var credentials = rest.slice(0, at);
		rest = rest.slice(at + 1);
		var sep = credentials.indexOf(':');
		if (sep >= 0) {
			user = credentials.slice(0, sep);
			passwd = credentials.slice(sep + 1);
		} else {
			user = credentials;
		}
	}

	var host = rest;
	var port = '';
	var colon = rest.lastIndexOf(':');
	// 尾巴不是純數字就不是埠號 (IPv6 的 "[::1]" 會走到這裡)
	if (colon >= 0 && /^\d+$/.test(rest.slice(colon + 1))) {
		host = rest.slice(0, colon);
		port = rest.slice(colon + 1);
	} else {
		// 沒有埠號時把結尾的冒號吃掉, 順便把以前存壞的 "http://:" 收回成「沒有代理」
		host = host.replace(/:+$/, '');
	}

	proxy_protocol = protocol.toUpperCase();
	proxy_user = user;
	proxy_passwd = passwd;
	proxy_ip = host;
	proxy_port = port;

	dataArrays.proxy_protocol = proxy_protocol;
	dataArrays.proxy_ip = proxy_ip;
	dataArrays.proxy_port = proxy_port;
	dataArrays.proxy_user = proxy_user;
	dataArrays.proxy_passwd = proxy_passwd;
}

// 把拆開的五個欄位組回一條代理字串.
//
// 沒有主機就是「不使用代理」, 回空字串 —— 舊版無條件拼 protocol + ip + ':' +
// port, 使用者把代理欄位清空再保存就會寫進一條 "http://:", 下次開設定頁時
// parseProxy() 解析不出埠號, 整張表單就毀了.
function buildProxy() {
	var host = (dataArrays['proxy_ip'] || '').toString().trim();
	if (!host) return '';
	var protocol = (dataArrays['proxy_protocol'] || 'http').toString().toLowerCase();
	var port = (dataArrays['proxy_port'] || '').toString().trim();
	var user = (dataArrays['proxy_user'] || '').toString();
	var passwd = (dataArrays['proxy_passwd'] || '').toString();
	var credentials = (user.length && passwd.length) ? (user + ':' + passwd + '@') : '';
	return protocol + '://' + credentials + host + (port ? ':' + port : '');
}

function reloadSetting() {
	readJson();
	renderJson();
}

function readJson() {
	$.getJSON("data/config.json", function(data) {
		dataArrays = data;
		parseProxy(data.proxy); // 解析代理配置
	});
}

function renderJson() {
	for (var id of id_list) {
		if (id == 'proxy') continue; //代理设置已被分解
		if (id == 'browser_fingerprint') continue; //指纹设置已被分解
		var element = document.getElementById(id);
		// 模板裡沒有這個欄位就跳過: 少一個 input 不該讓後面的欄位全部不 render
		if (!element) continue;
		var idType = element.type;
		switch (idType) {
			case 'text':
			case 'number':
			case 'password':
				if (id  == 'multi-thread')  // 手动任务的默认线程数
					$('#manual_thread_limit').val(dataArrays[id]);
				$("#" + id).val(dataArrays[id]);
				break;
			case 'checkbox':
				$("#" + id).bootstrapSwitch('state', dataArrays[id]);
				break;
			case 'select-one':
				if (id == 'proxy_protocol') {
					var wanted = (dataArrays[id] || '').toString().toUpperCase();
					var known = $("#" + id).find('option').filter(function () {
						return $(this).text().trim().toUpperCase() === wanted
							|| (this.value || '').toUpperCase() === wanted;
					}).length > 0;
					// 對不上任何 option 的話 bootstrap-select 會把 selectedIndex
					// 設成 -1, 之後 .val() 回的是 null —— readSettings() 就再也
					// 跑不完, 保存鈕按下去連失敗提示都沒有. 沒設代理時退回 HTTP,
					// 反正 buildProxy() 看的是主機有沒有填.
					$("#" + id).selectpicker('val', known ? wanted : 'HTTP');
				} else {
					$("#" + id).find("option:contains('" + dataArrays[id] + "')")
						.prop("selected", true);
					$("#" + id).selectpicker('render');
				}
				break;

		}
	}
	// 渲染浏览器指纹子字段
	$('#browser_fingerprint_ja3').val(dataArrays.browser_fingerprint_ja3);
	$('#browser_fingerprint_akamai').val(dataArrays.browser_fingerprint_akamai);
}


function readSettings() {
	for (var id of id_list) {
		if (id == 'proxy') continue; //代理设置已被分解
		if (id == 'browser_fingerprint') continue; //指纹设置已被分解

		var element = document.getElementById(id);
		// 模板裡沒有這個欄位就跳過, 別把手上那份設定寫成 undefined
		if (!element) continue;
		var idType = element.type;
		switch (idType) {
			case 'number':
				// 空白欄位的 Number('') 是 0. check_frequency / multi-thread 這些
				// 設定在 Config.py 只有上限沒有下限, 存進一個 0 就會讓主迴圈完全
				// 不等待地一直去打動畫瘋. 讀不出數字就沿用原本的值.
				var raw = $("#" + id).val();
				if (raw !== null && raw !== '' && isFinite(Number(raw))) {
					dataArrays[id] = Number(raw);
				}
				break;
			case 'text':
			case 'password':
				dataArrays[id] = $("#" + id).val();
				break;
			case 'checkbox':
				dataArrays[id] = $("#" + id).is(":checked");
				break;
			case 'select-one':
				// 沒有選中的選項時 .val() 是 null —— 直接 .toLowerCase() 會把整個
				// 保存流程打斷在送出請求之前, 使用者只會看到按鈕沒反應
				if (id == 'proxy_protocol') {
					dataArrays[id] = ($("#proxy_protocol").val() || '').toLowerCase();
				} else if (id == 'download_resolution') {
					dataArrays[id] = ($("#download_resolution").val() || '').replace('P', '');
				} else {
					dataArrays[id] = $("#" + id).val();
				}
				break;
		}
	}
	// 合并代理配置 (整輪讀完才拼一次, 舊版寫在迴圈裡, 每個欄位都重算五遍)
	dataArrays["proxy"] = buildProxy();
	// 合并浏览器指纹配置
	dataArrays["browser_fingerprint"] = {
		"ja3": $("#browser_fingerprint_ja3").val(),
		"akamai": $("#browser_fingerprint_akamai").val()
	};

	$.ajax({
		url: './uploadConfig',
		type: 'post',
		dataType: 'json',
		headers: {
			"Content-Type": "application/json;charset=utf-8"
		},
		contentType: 'application/json; charset=utf-8',
		data: JSON.stringify(dataArrays),
		success: function(data) {
			// 向用户提示提交成功
			$('#uploadOk').show();
			$('#uploadFailed').hide();
			$('#uploadStatus').modal();
			reloadSetting();
		},
		error:function(status){
			// 向用户提示提交失败
			$('#uploadOk').hide();
			$('#uploadFailed').show();
			$('#uploadStatus').modal();
		}
	})
}

function getUA(){
	$('#ua').val(navigator.userAgent);
	alert("已取得當前瀏覽器UA");
}

function readManualConfig(){
	var manualData = {};
	var link = $('#manual_link').val();
	if (link.length == 0) {
		alert('請輸入影片鏈接！')
	} else {
		var sn = link.replace(/(https:\/\/)?ani\.gamer\.com\.tw\/animeVideo\.php\?sn=/i, '');
		manualData['sn'] = sn;
		
		var mode = $("#manual_mode").val();
		manualData['mode'] = mode;
		
		var resolution = $('#manual_resolution').val().replace('P', '');
		manualData['resolution'] = resolution;
		
		var classify = $('#manual_classify').is(":checked");
		manualData['classify'] = classify;
		
		var thread = $('#manual_thread_limit').val();
		manualData['thread'] = thread;

		var danmu = $('#manual_danmu').is(":checked");
		manualData['danmu'] = danmu;

		var auto_update_danmu = $('#manual_auto_update_danmu').is(":checked");
		manualData['auto_update_danmu'] = auto_update_danmu;

		var m3u8 = $('#manual_m3u8').is(":checked");
		manualData['m3u8'] = m3u8;
		
		$.ajax({
			url: '/manualTask',
			type: 'post',
			dataType: 'json',
			headers: {
				"Content-Type": "application/json;charset=utf-8"
			},
			contentType: 'application/json; charset=utf-8',
			data: JSON.stringify(manualData),
			success: function(data) {
				// 向用户提示提交成功
				$('#uploadOk').show();
				$('#uploadFailed').hide();
				$('#uploadStatus').modal();
				reloadSetting();
			},
			error:function(status){
				// 向用户提示提交失败
				$('#uploadOk').hide();
				$('#uploadFailed').show();
				$('#uploadStatus').modal();
			}
		})
	}
	
}

function postSnList(){
	var sn_list = $('#sn_list').val();
	
	$.ajax({
		url: './sn_list',
		type: 'post',
		dataType: 'text',
		headers: {
			"Content-Type": "text/plain; charset=utf-8"
		},
		contentType: 'text/plain; charset=utf-8',
		data: sn_list,
		success: function(data) {
			// 向用户提示提交成功
			$('#uploadOk').show();
			$('#uploadFailed').hide();
			$('#uploadStatus').modal();
			showSnList();
		},
		error:function(status){
			// 向用户提示提交失败
			$('#uploadOk').hide();
			$('#uploadFailed').show();
			$('#uploadStatus').modal();
		}
	})
}

function showSnList(){
	$.get("data/sn_list", function(data) {
		$("#sn_list").val(data);
	})
}


function appendWebConsoleOutput(text) {
	var output = $('#web_console_output');
	if (output.length === 0) return;
	var current = output.val();
	var next = current.length ? (current + "\n" + text) : text;
	output.val(next);
	output.scrollTop(output[0].scrollHeight);
}


function formatCommandHelp(commands) {
	if (!commands || !commands.length) {
		return '沒有可用指令';
	}
	var lines = ['可用指令:'];
	for (var i = 0; i < commands.length; i++) {
		var item = commands[i];
		lines.push('- ' + item.name + ' : ' + (item.help || ''));
	}
	return lines.join('\n');
}


function runWebConsoleCommand(command) {
	var cmd = command || $('#web_console_command').val().trim();
	if (!cmd) {
		appendWebConsoleOutput('[錯誤] 請輸入指令');
		return;
	}

	appendWebConsoleOutput('> ' + cmd);

	$.ajax({
		url: '/console/command',
		type: 'post',
		dataType: 'json',
		headers: {
			"Content-Type": "application/json;charset=utf-8"
		},
		contentType: 'application/json; charset=utf-8',
		data: JSON.stringify({ command: cmd }),
		success: function(data) {
			if (data.help) {
				appendWebConsoleOutput(formatCommandHelp(data.commands));
			} else {
				appendWebConsoleOutput((data.success ? '[成功] ' : '[失敗] ') + (data.message || ''));
			}
		},
		error: function(xhr) {
			var msg = '指令執行失敗';
			if (xhr.responseJSON && xhr.responseJSON.message) {
				msg = xhr.responseJSON.message;
			}
			appendWebConsoleOutput('[失敗] ' + msg);
		}
	});
}


function runQuickCommand(command) {
	$('#web_console_command').val(command);
	runWebConsoleCommand(command);
}


$(document).on('keydown', '#web_console_command', function(e) {
	if (e.key === 'Enter') {
		e.preventDefault();
		runWebConsoleCommand();
	}
});