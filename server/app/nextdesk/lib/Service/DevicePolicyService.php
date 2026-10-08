<?php

declare(strict_types=1);

namespace OCA\NextDesk\Service;

use InvalidArgumentException;
use OCA\NextDesk\AppInfo\Application;
use OCP\IAppConfig;

/**
 * Where this server's NextDesk machines get their device policy: one URL for all of them.
 *
 * The policy file itself is signed (NextDesk's key, or the machine's NEXTDESK_POLICY_KEYRING), so
 * this setting can only point machines at a policy that is signed; it is public, so machines and
 * the installer can read it before anyone signs in.
 */
class DevicePolicyService {
    private const KEY = 'device_policy_url';

    public function __construct(
        private IAppConfig $appConfig,
    ) {
    }

    public function getUrl(): string {
        return $this->appConfig->getValueString(Application::APP_ID, self::KEY, '');
    }

    /** An https URL, or '' to remove it. */
    public function setUrl(string $url): void {
        $url = trim($url);
        if ($url !== '' && !preg_match('#^https://[A-Za-z0-9.-]+(:\d+)?/\S*$#', $url)) {
            throw new InvalidArgumentException('The device policy URL must be an https:// URL');
        }
        if ($url === '') {
            $this->appConfig->deleteKey(Application::APP_ID, self::KEY);
        } else {
            $this->appConfig->setValueString(Application::APP_ID, self::KEY, $url);
        }
    }
}
