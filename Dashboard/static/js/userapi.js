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


function getDashboardBootstrap() {
    var bootstrapElement;
    var bootstrap = window.__AGP_BOOTSTRAP__;
    if (bootstrap && typeof bootstrap === 'object') {
        return bootstrap;
    }

    bootstrapElement = document.getElementById('agp-dashboard-bootstrap');
    if (bootstrapElement) {
        try {
            bootstrap = JSON.parse(bootstrapElement.textContent || '{}');
            window.__AGP_BOOTSTRAP__ = bootstrap;
            return bootstrap;
        } catch (error) {
            console.warn('Failed to parse dashboard bootstrap:', error);
        }
    }

    return {};
}


function getBootstrappedServerInfo() {
    return getDashboardBootstrap().serverInfo || null;
}


function getBootstrappedCurrentUser() {
    return getDashboardBootstrap().currentUser || null;
}


function isLoggedIn() {
    var bootstrap = getDashboardBootstrap();
    if (typeof bootstrap.loggedIn === 'boolean') {
        return bootstrap.loggedIn;
    }
    return getCookieByName('logined') === 'true';
}


window.dashboardApi = {
    parseCookie: parseCookie,
    getCookieByName: getCookieByName,
    getBootstrap: getDashboardBootstrap,
    getServerInfoSnapshot: getBootstrappedServerInfo,
    getCurrentUserSnapshot: getBootstrappedCurrentUser,
    isLoggedIn: isLoggedIn,
};


var serverinfo = null;
async function getServerInfo(key) {
    if (serverinfo == null) {
        serverinfo = getBootstrappedServerInfo();
        if (serverinfo == null) {
            serverinfo = await fetch('./get_server_info')
                .then(res => res.json())
                .catch(function (error) {
                    console.error('Error:', error);
                    return {};
                });
        }
    }

    if (key) {
        return serverinfo ? serverinfo[key] : undefined;
    }

    return serverinfo || {};
}


function appendNavLink(navbar, href, text) {
    var item = document.createElement('li');
    item.className = 'nav-item my-navbar';

    var link = document.createElement('a');
    link.className = 'nav-link';
    link.href = href;
    link.textContent = text;

    item.appendChild(link);
    navbar.appendChild(item);
}


function markLoggedInCookie(value) {
    document.cookie = 'logined=' + value + '; expires=Fri, 31 Dec 9999 23:59:59 GMT; path=/';
}


async function fetchCurrentUser() {
    var currentUser = getBootstrappedCurrentUser();
    if (currentUser) {
        return currentUser;
    }

    if (!isLoggedIn()) {
        return null;
    }

    return fetch('./userinfo', {
        method: 'POST',
        credentials: 'include',
        headers: {
            'Content-Type': 'application/json'
        },
        body: JSON.stringify({ action: 'get' })
    }).then(res => res.json()).then(function (data) {
        if (data.status == '200') {
            return data;
        }
        return null;
    }).catch(function (error) {
        console.error('Error:', error);
        return null;
    });
}


async function userMain() {
    var navbar = document.querySelector('.navbar-nav');
    if (!navbar) {
        setTimeout(userMain, 100);
        return;
    }

    navbar.innerHTML = '';

    try {
        var info = await getServerInfo();
        if (info.online_watch) {
            appendNavLink(navbar, './watch', '線上看');
        }

        if (!info.user_control) {
            markLoggedInCookie('false');
            return;
        }

        var currentUser = await fetchCurrentUser();
        if (currentUser) {
            markLoggedInCookie('true');
            if (currentUser.role == 'admin') {
                appendNavLink(navbar, './control', '主控台');
                appendNavLink(navbar, './usermanage', '用戶管理');
            }
            appendNavLink(navbar, './userinfo', currentUser.username || '帳號');
            appendNavLink(navbar, './logout', '登出');
            return;
        }

        markLoggedInCookie('false');
        appendNavLink(navbar, './login', '登入');
        if (info.user_control_allow_register === true) {
            appendNavLink(navbar, './register', '註冊');
        }
    } catch (err) {
        markLoggedInCookie('false');
        if (!navbar.children.length) {
            appendNavLink(navbar, './login', '登入');
        }
        console.warn(err);
    }
}


$(document).ready(function () {
    userMain();
});
