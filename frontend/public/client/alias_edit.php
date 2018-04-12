<?php
/**
 * i-MSCP - internet Multi Server Control Panel
 * Copyright (C) 2010-2018 by Laurent Declercq <l.declercq@nuxwin.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

use iMSCP\TemplateEngine;
use iMSCP\VirtualFileSystem as VirtualFileSystem;
use iMSCP_Events as Events;
use iMSCP_Events_Event as Event;
use iMSCP_Registry as Registry;

/***********************************************************************************************************************
 * Functions
 */

/**
 * Get domain alias data
 *
 * @access private
 * @param int $domainAliasId Subdomain unique identifier
 * @return array|bool Domain alias data or FALSE on error
 */
function _client_getAliasData($domainAliasId)
{
    static $domainAliasData = NULL;

    if (NULL !== $domainAliasData) {
        return $domainAliasData;
    }

    $stmt = exec_query(
        "
            SELECT alias_name, alias_ips, alias_mount, alias_document_root, url_forward, type_forward, host_forward
            FROM domain_aliases
            WHERE alias_id = ?
            AND domain_id = ?
            AND alias_status = 'ok'
        ",
        [$domainAliasId, get_user_domain_id($_SESSION['user_id'])]
    );

    if (!$stmt->rowCount()) {
        return false;
    }

    $domainAliasData = $stmt->fetch();
    $domainAliasData['alias_name_utf8'] = decode_idna($domainAliasData['alias_name']);
    return $domainAliasData;
}

/**
 * Edit domain alias
 *
 * @return bool TRUE on success, FALSE on failure
 */
function client_editDomainAlias()
{
    isset($_GET['id']) or showBadRequestErrorPage();

    $domainAliasId = intval($_GET['id']);
    $domainAliasData = _client_getAliasData($domainAliasId);
    $domainAliasData !== FALSE or showBadRequestErrorPage();

    // Check for domain alias IP addresses
    $domainAliasIps = [];
    if (empty($_POST['alias_ips'])) {
        set_page_message(tohtml(tr('You must assign at least one IP address to that domain alias.')), 'error');
        return false;
    } elseif (!is_array($_POST['alias_ips'])) {
        showBadRequestErrorPage();
    } else {
        $clientIps = explode(',', get_domain_default_props($_SESSION['user_id'])['domain_client_ips']);
        $domainAliasIps = array_intersect($_POST['alias_ips'], $clientIps);
        if (count($domainAliasIps) < count($_POST['alias_ips'])) {
            // Situation where unknown IP address identifier has been submitten
            showBadRequestErrorPage();
        }
    }

    // Default values
    $documentRoot = $domainAliasData['alias_document_root'];
    $forwardUrl = 'no';
    $forwardType = NULL;
    $forwardHost = 'Off';

    // Check for URL forwarding option
    if (isset($_POST['url_forwarding']) && $_POST['url_forwarding'] == 'yes' && isset($_POST['forward_type'])
        && in_array($_POST['forward_type'], ['301', '302', '303', '307', 'proxy'], true)
    ) {
        isset($_POST['forward_url_scheme']) && isset($_POST['forward_url']) or showBadRequestErrorPage();

        $forwardUrl = clean_input($_POST['forward_url_scheme']) . clean_input($_POST['forward_url']);
        $forwardType = clean_input($_POST['forward_type']);
        if ($forwardType == 'proxy' && isset($_POST['forward_host'])) {
            $forwardHost = 'On';
        }

        try {
            try {
                $uri = iMSCP_Uri_Redirect::fromString($forwardUrl);
            } catch (Zend_Uri_Exception $e) {
                throw new iMSCP_Exception(tr('Forward URL %s is not valid.', "<strong>$forwardUrl</strong>"));
            }

            $uri->setHost(encode_idna(mb_strtolower($uri->getHost()))); // Normalize URI host
            $uri->setPath(rtrim(utils_normalizePath($uri->getPath()), '/') . '/'); // Normalize URI path

            if ($uri->getHost() == $domainAliasData['alias_name'] && ($uri->getPath() == '/' && in_array($uri->getPort(), ['', 80, 443]))) {
                throw new iMSCP_Exception(
                    tr('Forward URL %s is not valid.', "<strong>$forwardUrl</strong>") . ' '
                    . tr('Domain alias %s cannot be forwarded on itself.', "<strong>{$domainAliasData['alias_name_utf8']}</strong>")
                );
            }

            if ($forwardType == 'proxy') {
                $port = $uri->getPort();
                if ($port && $port < 1025) {
                    throw new iMSCP_Exception(tr('Unallowed port in forward URL. Only ports above 1024 are allowed.', 'error'));
                }
            }

            $forwardUrl = $uri->getUri();
        } catch (Exception $e) {
            set_page_message($e->getMessage(), 'error');
            return false;
        }
    } // Check for alternative DocumentRoot option
    elseif (isset($_POST['document_root'])) {
        $documentRoot = utils_normalizePath('/' . clean_input($_POST['document_root']));
        if ($documentRoot !== '') {
            $vfs = new VirtualFileSystem($_SESSION['user_logged'], $domainAliasData['alias_mount'] . '/htdocs');
            if ($documentRoot !== '/' && !$vfs->exists($documentRoot, VirtualFileSystem::VFS_TYPE_DIR)) {
                set_page_message(tr('The new document root must pre-exists inside the /htdocs directory.'), 'error');
                return false;
            }
        }
        $documentRoot = utils_normalizePath('/htdocs' . $documentRoot);
    }

    Registry::get('iMSCP_Application')->getEventsManager()->dispatch(iMSCP_Events::onBeforeEditDomainAlias, [
        'domainAliasId'  => $domainAliasId,
        'domainAliasIps' => $domainAliasIps,
        'mountPoint'     => $domainAliasData['alias_mount'],
        'documentRoot'   => $documentRoot,
        'forwardUrl'     => $forwardUrl,
        'forwardType'    => $forwardType,
        'forwardHost'    => $forwardHost
    ]);
    exec_query(
        '
          UPDATE domain_aliases
          SET alias_document_root = ?, alias_ips = ?, url_forward = ?, type_forward = ?, host_forward = ?, alias_status = ?
          WHERE alias_id = ?
        ',
        [$documentRoot, implode(',', $domainAliasIps), $forwardUrl, $forwardType, $forwardHost, 'tochange', $domainAliasId]
    );
    Registry::get('iMSCP_Application')->getEventsManager()->dispatch(iMSCP_Events::onAfterEditDomainAlias, [
        'domainAliasId'  => $domainAliasId,
        'domainAliasIps' => $domainAliasIps,
        'mountPoint'     => $domainAliasData['alias_mount'],
        'documentRoot'   => $documentRoot,
        'forwardUrl'     => $forwardUrl,
        'forwardType'    => $forwardType,
        'forwardHost'    => $forwardHost
    ]);
    send_request();
    write_log(sprintf('%s updated properties of the %s domain alias', $_SESSION['user_logged'], $domainAliasData['alias_name_utf8']), E_USER_NOTICE);
    return true;
}

/**
 * Generate page
 *
 * @param $tpl TemplateEngine
 * @return void
 */
function client_generatePage($tpl)
{
    isset($_GET['id']) or showBadRequestErrorPage();

    $domainAliasId = intval($_GET['id']);
    $domainAliasData = _client_getAliasData($domainAliasId);
    $domainAliasData !== FALSE or showBadRequestErrorPage();
    $domainAliasData['alias_ips'] = explode(',', $domainAliasData['alias_ips']);
    $forwardHost = 'Off';

    if (empty($_POST)) {
        client_generate_ip_list($tpl, $_SESSION['user_id'], $domainAliasData['alias_ips']);

        $documentRoot = strpos($domainAliasData['alias_document_root'], '/htdocs') !== FALSE
            ? substr($domainAliasData['alias_document_root'], 7) : '';

        if ($domainAliasData['url_forward'] != 'no') {
            $urlForwarding = true;
            $uri = iMSCP_Uri_Redirect::fromString($domainAliasData['url_forward']);
            $uri->setHost(decode_idna($uri->getHost()));
            $forwardUrlScheme = $uri->getScheme() . '://';
            $forwardUrl = substr($uri->getUri(), strlen($forwardUrlScheme));
            $forwardType = $domainAliasData['type_forward'];
            $forwardHost = $domainAliasData['host_forward'];
        } else {
            $urlForwarding = false;
            $forwardUrlScheme = 'http';
            $forwardUrl = '';
            $forwardType = '302';
        }
    } else {
        client_generate_ip_list($tpl, $_SESSION['user_id'], isset($_POST['alias_ips']) && is_array($_POST['alias_ips']) ? $_POST['alias_ips'] : []);

        $documentRoot = isset($_POST['document_root']) ? $_POST['document_root'] : '';
        $urlForwarding = isset($_POST['url_forwarding']) && $_POST['url_forwarding'] == 'yes' ? true : false;
        $forwardUrlScheme = isset($_POST['forward_url_scheme']) ? $_POST['forward_url_scheme'] : 'http://';
        $forwardUrl = isset($_POST['forward_url']) ? $_POST['forward_url'] : '';
        $forwardType = (
            isset($_POST['forward_type']) && in_array($_POST['forward_type'], ['301', '302', '303', '307', 'proxy'], true)
        ) ? $_POST['forward_type'] : '302';

        if ($forwardType == 'proxy' && isset($_POST['forward_host'])) {
            $forwardHost = 'On';
        }
    }

    $tpl->assign([
        'DOMAIN_ALIAS_ID'    => $domainAliasId,
        'DOMAIN_ALIAS_NAME'  => tohtml($domainAliasData['alias_name_utf8']),
        'DOCUMENT_ROOT'      => tohtml($documentRoot),
        'FORWARD_URL_YES'    => ($urlForwarding) ? ' checked' : '',
        'FORWARD_URL_NO'     => ($urlForwarding) ? '' : ' checked',
        'HTTP_YES'           => ($forwardUrlScheme == 'http://') ? ' selected' : '',
        'HTTPS_YES'          => ($forwardUrlScheme == 'https://') ? ' selected' : '',
        'FORWARD_URL'        => tohtml($forwardUrl, 'htmlAttr'),
        'FORWARD_TYPE_301'   => ($forwardType == '301') ? ' checked' : '',
        'FORWARD_TYPE_302'   => ($forwardType == '302') ? ' checked' : '',
        'FORWARD_TYPE_303'   => ($forwardType == '303') ? ' checked' : '',
        'FORWARD_TYPE_307'   => ($forwardType == '307') ? ' checked' : '',
        'FORWARD_TYPE_PROXY' => ($forwardType == 'proxy') ? ' checked' : '',
        'FORWARD_HOST'       => ($forwardHost == 'On') ? ' checked' : ''
    ]);

    // Cover the case where URL forwarding feature is activated and that the
    // default /htdocs directory doesn't exist yet
    if ($domainAliasData['url_forward'] != 'no') {
        $vfs = new VirtualFileSystem($_SESSION['user_logged'], $domainAliasData['alias_mount']);
        if (!$vfs->exists('/htdocs')) {
            $tpl->assign('DOCUMENT_ROOT_BLOC', '');
            return;
        }
    }

    # Set parameters for the FTP chooser
    $_SESSION['ftp_chooser_domain_id'] = get_user_domain_id($_SESSION['user_id']);
    $_SESSION['ftp_chooser_user'] = $_SESSION['user_logged'];
    $_SESSION['ftp_chooser_root_dir'] = utils_normalizePath($domainAliasData['alias_mount'] . '/htdocs');
    $_SESSION['ftp_chooser_hidden_dirs'] = [];
    $_SESSION['ftp_chooser_unselectable_dirs'] = [];
}

/***********************************************************************************************************************
 * Main
 */


require_once 'imscp-lib.php';

check_login('user');
Registry::get('iMSCP_Application')->getEventsManager()->dispatch(iMSCP_Events::onClientScriptStart);
customerHasFeature('domain_aliases') or showBadRequestErrorPage();

if (!empty($_POST) && client_editDomainAlias()) {
    set_page_message(tr('Domain alias successfully scheduled for update.'), 'success');
    redirectTo('domains_manage.php');
}

$tpl = new TemplateEngine();
$tpl->define([
    'layout'             => 'shared/layouts/ui.tpl',
    'page'               => 'client/alias_edit.tpl',
    'page_message'       => 'layout',
    'ip_entry'           => 'page',
    'document_root_bloc' => 'page'
]);
$tpl->assign([
    'TR_PAGE_TITLE'             => tohtml(tr('Client / Domains / Edit Domain Alias')),
    'TR_DOMAIN_ALIAS'           => tohtml(tr('Domain alias')),
    'TR_DOMAIN_ALIAS_NAME'      => tohtml(tr('Name')),
    'TR_DOMAIN_ALIAS_IPS'       => tohtml(tr('IP addresses')),
    'TR_DOCUMENT_ROOT'          => tohtml(tr('Document root')),
    'TR_DOCUMENT_ROOT_TOOLTIP'  => tohtml(tr("You can set an alternative document root. This is mostly needed when using a PHP framework such as Symfony. Note that the new document root will live inside the default  `/htdocs' document root. Be aware that the directory for the new document root must pre-exist."), 'htmlAttr'),
    'TR_CHOOSE_DIR'             => tohtml(tr('Choose dir')),
    'TR_URL_FORWARDING'         => tohtml(tr('URL forwarding')),
    'TR_FORWARD_TO_URL'         => tohtml(tr('Forward to URL')),
    'TR_URL_FORWARDING_TOOLTIP' => tohtml(tr('Allows to forward any request made to this domain to a specific URL.'), 'htmlAttr'),
    'TR_YES'                    => tohtml(tr('Yes')),
    'TR_NO'                     => tohtml(tr('No')),
    'TR_HTTP'                   => tohtml('http://'),
    'TR_HTTPS'                  => tohtml('https://'),
    'TR_FORWARD_TYPE'           => tohtml(tr('Forward type')),
    'TR_301'                    => tohtml('301'),
    'TR_302'                    => tohtml('302'),
    'TR_303'                    => tohtml('303'),
    'TR_307'                    => tohtml('307'),
    'TR_PROXY'                  => tohtml(tr('Proxy')),
    'TR_PROXY_PRESERVE_HOST'    => tohtml(tr('Preserve Host')),
    'TR_UPDATE'                 => tohtml(tr('Update'), 'htmlAttr'),
    'TR_CANCEL'                 => tohtml(tr('Cancel'))
]);

Registry::get('iMSCP_Application')->getEventsManager()->registerListener(Events::onGetJsTranslations, function (Event $e) {
    $translations = $e->getParam('translations');
    $translations['core']['close'] = tr('Close');
    $translations['core']['ftp_directories'] = tr('Select your own document root');
    $translations['core']['available'] = tr('Available');
    $translations['core']['assigned'] = tr('Assigned');
});

generateNavigation($tpl);
client_generatePage($tpl);
generatePageMessage($tpl);

$tpl->parse('LAYOUT_CONTENT', 'page');
Registry::get('iMSCP_Application')->getEventsManager()->dispatch(iMSCP_Events::onClientScriptEnd, ['templateEngine' => $tpl]);
$tpl->prnt();

unsetMessages();