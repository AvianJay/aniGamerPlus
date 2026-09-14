layui.use('element', function () {
    let element = layui.element;
    let reconnectTimer = null;
    let socket = null;

    function buildTasksProgressUrl() {
        const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        return `${protocol}//${window.location.host}/data/tasks_progress`;
    }

    // 任務名稱是動畫瘋來的作品標題, 不是我們自己寫的字串.
    //
    // Anime.py 在「正在解析」那一段就先把原始標題放進 tasks_progress_rate 了,
    // 要等解析完才會換成 legalize_filename() 洗過的檔名 —— 而洗檔名只處理
    // < > 這類路徑非法字元, 不是為了 HTML 準備的. 所以這裡一律自己逃脫.
    function escapeHtml(value) {
        return String(value === undefined || value === null ? '' : value)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    function renderTasks(data) {
        const taskIds = new Set(Object.keys(data || {}));

        if (taskIds.size === 0) {
            $('#no_task').show();
        } else {
            $('#no_task').hide();
        }

        $('#task_info_panel').children('.layui-card').each(function () {
            const taskId = this.id;
            if (!taskIds.has(taskId)) {
                $(this).remove();
            }
        });

        for (const sn in data) {
            const task = data[sn];
            if ($('#' + sn).length > 0) {
                // .text() 而不是 .html(): 標題裡的 < 就是一個 <
                $('#status' + sn).text(task.status === undefined ? '' : task.status);
                $('#header' + sn).text(task.filename === undefined ? '' : task.filename);
                element.progress(sn, Math.round(task.rate) + '%');
                continue;
            }

            const safeSn = escapeHtml(sn);
            const taskItemTemplate = `
                <div class="layui-col-xs12 layui-card" id="${safeSn}">
                    <div class="layui-card-header" style="height:auto !important;" id="header${safeSn}">${escapeHtml(task.filename)}</div>
                    <div class="layui-card-body layui-row">
                        <div class="layui-col-xs3" style="text-align: center;" id="status${safeSn}">${escapeHtml(task.status)}</div>
                        <div class="layui-col-xs9" style="padding: 3px;">
                            <div class="layui-progress layui-progress-big" lay-showpercent="true" lay-filter="${safeSn}">
                                <div class="layui-progress-bar" lay-percent="0%">
                                    <span class="layui-progress-text">0%</span>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            `;
            $('#task_info_panel').prepend(taskItemTemplate);
            element.progress(sn, Math.round(task.rate) + '%');
        }
    }

    function scheduleReconnect() {
        if (reconnectTimer) {
            clearTimeout(reconnectTimer);
        }
        reconnectTimer = setTimeout(connectMonitorSocket, 1500);
    }

    function connectMonitorSocket() {
        if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) {
            return;
        }

        socket = new WebSocket(buildTasksProgressUrl());

        socket.onmessage = function (evt) {
            try {
                const data = JSON.parse(evt.data);
                renderTasks(data);
            } catch (error) {
                console.warn('Failed to parse monitor payload:', error);
            }
        };

        socket.onclose = function () {
            scheduleReconnect();
        };

        socket.onerror = function () {
            if (socket) {
                socket.close();
            }
        };
    }

    connectMonitorSocket();
});
