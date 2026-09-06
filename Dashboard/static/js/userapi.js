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


/* 帳號那幾條連結攤平擺在標題列上就是五顆按鈕, iPad 寬度一來還會擠成第二排.
   收進一個選單, 列上只剩線上看跟自己的名字. 只有新外殼 (.agp-usernav) 這樣收 ——
   控制臺跟用戶管理那兩頁是 bootstrap 的 navbar, 沒有這裡的樣式可以用 */
function appendNavMenu(navbar, username, links) {
    var item = document.createElement('li');
    item.className = 'nav-item my-navbar agp-navmenu-item';

    var details = document.createElement('details');
    details.className = 'agp-navmenu';

    var summary = document.createElement('summary');
    summary.className = 'nav-link agp-navmenu-toggle';

    var avatar = document.createElement('span');
    avatar.className = 'agp-navmenu-avatar';
    avatar.textContent = String(username || '?').trim().charAt(0).toUpperCase();
    summary.appendChild(avatar);

    var name = document.createElement('span');
    name.className = 'agp-navmenu-name';
    name.textContent = username || '帳號';
    summary.appendChild(name);
    details.appendChild(summary);

    var panel = document.createElement('div');
    panel.className = 'agp-navmenu-panel';
    links.forEach(function (link) {
        var anchor = document.createElement('a');
        anchor.className = 'nav-link';
        anchor.href = link[0];
        anchor.textContent = link[1];
        panel.appendChild(anchor);
    });
    details.appendChild(panel);

    item.appendChild(details);
    navbar.appendChild(item);

    /* details 自己不會關. 開著離開它就一直蓋在頁面上 */
    document.addEventListener('click', function (event) {
        if (!details.contains(event.target)) {
            details.removeAttribute('open');
        }
    });
}


/* 播放頁的頁籤列自己就有一顆「線上看」而且是選中的那顆, 右上角再放一條
   只是同一個地方寫兩遍 */
function isOnlineWatchPage() {
    return /\/watch\/?$/.test(window.location.pathname);
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

    var folded = navbar.classList.contains('agp-usernav');

    try {
        var info = await getServerInfo();
        if (info.online_watch && !(folded && isOnlineWatchPage())) {
            appendNavLink(navbar, './watch', '線上看');
        }

        if (!info.user_control) {
            markLoggedInCookie('false');
            return;
        }

        var currentUser = await fetchCurrentUser();
        if (currentUser) {
            markLoggedInCookie('true');
            var links = [];
            if (currentUser.role == 'admin') {
                links.push(['./control', '主控台']);
                links.push(['./usermanage', '用戶管理']);
            }
            /* 收起來的時候名字已經印在按鈕上了, 裡面再寫一次很怪 */
            links.push(['./userinfo', folded ? '帳號資訊' : (currentUser.username || '帳號')]);
            links.push(['./logout', '登出']);
            if (folded) {
                appendNavMenu(navbar, currentUser.username, links);
            } else {
                links.forEach(function (link) { appendNavLink(navbar, link[0], link[1]); });
            }
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
