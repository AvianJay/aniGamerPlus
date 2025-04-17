function parseCookie() {
    var cookieObj = {};
    var cookieAry = document.cookie.split(';');
    var cookie;

    for (var i = 0, l = cookieAry.length; i < l; ++i) {
        cookie = jQuery.trim(cookieAry[i]);
        cookie = cookie.split('=');
        cookieObj[cookie[0]] = cookie[1];
    }

    return cookieObj;
}


function getCookieByName(name) {
    var value = parseCookie()[name];
    if (value) {
        value = decodeURIComponent(value);
    }

    return value;
}

var serverinfo = null;
async function getServerInfo(key) {
    if (serverinfo == null) {
        serverinfo = await fetch('./get_server_info').then(res => res.json()).then(function (data) {
            if (key) {
                return data[key];
            } else {
                return data;
            }
        }).catch(function (error) {
            console.error('Error:', error);
        });
    }
    return serverinfo;
}

async function userMain() {
    try {
        navbar = document.querySelector('.navbar-nav');
        if (!navbar) {
            setTimeout(userMain, 100);
            return;
        }
        if (await getServerInfo('online_watch')) {
            var watchlink = document.createElement('li');
            watchlink.className = 'nav-item my-navbar';
            watchlink.innerHTML = '<a class="nav-link" href="./watch">線上看</a>';
            navbar.appendChild(watchlink);
        }
        if (await getServerInfo('user_control')) {
            var login = getCookieByName('logined');
            if (login == 'true' && getCookieByName('token') != null) {
                fetch('./userinfo', {
                    method: 'POST',
                    credentials: 'include',
                    headers: {
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({ action: "get" })
                }).then(res => res.json()).then(async function (data) {
                    if (data.status == '200') {
                        document.cookie = 'logined=true; expires=Fri, 31 Dec 9999 23:59:59 GMT';
                        if (data.role == 'admin') {
                            var adminlink = document.createElement('li');
                            adminlink.className = 'nav-item my-navbar';
                            adminlink.innerHTML = '<a class="nav-link" href="./control">主控台</a>';
                            navbar.appendChild(adminlink);
                        }
                        var userlink = document.createElement('li');
                        userlink.className = 'nav-item my-navbar';
                        userlink.innerHTML = '<a class="nav-link" href="./userinfo">' + data.username + '</a>';
                        navbar.appendChild(userlink);
                        var logoutlink = document.createElement('li');
                        logoutlink.className = 'nav-item my-navbar';
                        logoutlink.innerHTML = '<a class="nav-link" href="./logout">登出</a>';
                        navbar.appendChild(logoutlink);
                    } else {
                        document.cookie = 'logined=false; expires=Fri, 31 Dec 9999 23:59:59 GMT';
                        var loginlink = document.createElement('li');
                        loginlink.className = 'nav-item my-navbar';
                        loginlink.innerHTML = '<a class="nav-link" href="./login">登入</a>';
                        navbar.appendChild(loginlink);
                        if (await getServerInfo('user_control_allow_register') == true) {
                            var registerlink = document.createElement('li');
                            registerlink.className = 'nav-item my-navbar';
                            registerlink.innerHTML = '<a class="nav-link" href="./register">註冊</a>';
                            navbar.appendChild(registerlink);
                        }
                    }
                }).catch(function (error) {
                    console.error('Error:', error);
                });
            } else {
                document.cookie = 'logined=false; expires=Fri, 31 Dec 9999 23:59:59 GMT';
                var loginlink = document.createElement('li');
                loginlink.className = 'nav-item my-navbar';
                loginlink.innerHTML = '<a class="nav-link" href="./login">登入</a>';
                navbar.appendChild(loginlink);
                if (await getServerInfo('user_control_allow_register') == true) {
                    var registerlink = document.createElement('li');
                    registerlink.className = 'nav-item my-navbar';
                    registerlink.innerHTML = '<a class="nav-link" href="./register">註冊</a>';
                    navbar.appendChild(registerlink);
                }
            }
        } else {
            document.cookie = 'logined=false; expires=Fri, 31 Dec 9999 23:59:59 GMT';
            var loginlink = document.createElement('li');
            loginlink.className = 'nav-item my-navbar';
            loginlink.innerHTML = '<a class="nav-link" href="./login">登入</a>';
            navbar.appendChild(loginlink);
            if (await getServerInfo('user_control_allow_register') == true) {
                var registerlink = document.createElement('li');
                registerlink.className = 'nav-item my-navbar';
                registerlink.innerHTML = '<a class="nav-link" href="./register">註冊</a>';
                navbar.appendChild(registerlink);
            }
        }
    } catch (err) {
        document.cookie = 'logined=false; expires=Fri, 31 Dec 9999 23:59:59 GMT';
        var loginlink = document.createElement('li');
        loginlink.className = 'nav-item my-navbar';
        loginlink.innerHTML = '<a class="nav-link" href="./login">登入</a>';
        navbar.appendChild(loginlink);
        if (await getServerInfo('user_control_allow_register') == 'true') {
            var registerlink = document.createElement('li');
            registerlink.className = 'nav-item my-navbar';
            registerlink.innerHTML = '<a class="nav-link" href="./register">註冊</a>';
            navbar.appendChild(registerlink);
        }
        console.warn(err);
    }
}

$(document).ready(function () {
    userMain();
});
