layui.use('element', function () {
    let element = layui.element;
    let reconnectTimer = null;
    let socket = null;

    function buildTasksProgressUrl() {
        const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        return `${protocol}//${window.location.host}/data/tasks_progress`;
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
                $('#status' + sn).html(task.status);
                $('#header' + sn).html(task.filename);
                element.progress(sn, Math.round(task.rate) + '%');
                continue;
            }

            const taskItemTemplate = `
                <div class="layui-col-xs12 layui-card" id="${sn}">
                    <div class="layui-card-header" style="height:auto !important;" id="header${sn}">${task.filename}</div>
                    <div class="layui-card-body layui-row">
                        <div class="layui-col-xs3" style="text-align: center;" id="status${sn}">${task.status}</div>
                        <div class="layui-col-xs9" style="padding: 3px;">
                            <div class="layui-progress layui-progress-big" lay-showpercent="true" lay-filter="${sn}">
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
