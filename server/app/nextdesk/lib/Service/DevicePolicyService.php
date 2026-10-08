<?php

declare(strict_types=1);

namespace OCA\NextDesk\Service;

use InvalidArgumentException;
use OCA\NextDesk\AppInfo\Application;
use OCP\IAppConfig;

/**
 * Where this server's NextDesk machines get their device policy.
 *
 * - url: the full URL of the main policy file.
 * - per_hostname: machines first look for <directory of url>/<group>.json, where group is the
 *   part of their hostname before the first '-' (sales-001 -> sales.json); the main policy is the
 *   fallback (no '-' in the name, or no such file).
 * - departments: the groups the installer offers (it proposes <department>-<6 hex> as the name).
 *
 * The policy files themselves are signed (NextDesk's key, or the machine's
 * NEXTDESK_POLICY_KEYRING), so these settings can only point machines at policies that are
 * signed; they are public, so machines and the installer can read them before anyone signs in.
 */
class DevicePolicyService {
    private const KEY = 'device_policy_url';
    private const KEY_PER_HOSTNAME = 'device_policy_per_hostname';
    private const KEY_DEPARTMENTS = 'device_policy_departments';
    /** A hostname group: the part of a hostname before the first '-'. */
    public const DEPARTMENT_RE = '/^[a-z0-9]{1,30}$/';

    public function __construct(
        private IAppConfig $appConfig,
    ) {
    }

    /** @return array{url: string, per_hostname: bool, departments: list<string>} */
    public function get(): array {
        return [
            'url' => $this->getUrl(),
            'per_hostname' => $this->getPerHostname(),
            'departments' => $this->getDepartments(),
        ];
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

    public function getPerHostname(): bool {
        return $this->appConfig->getValueBool(Application::APP_ID, self::KEY_PER_HOSTNAME, false);
    }

    public function setPerHostname(bool $on): void {
        if ($on) {
            $this->appConfig->setValueBool(Application::APP_ID, self::KEY_PER_HOSTNAME, true);
        } else {
            $this->appConfig->deleteKey(Application::APP_ID, self::KEY_PER_HOSTNAME);
        }
    }

    /** @return list<string> */
    public function getDepartments(): array {
        $value = $this->appConfig->getValueString(Application::APP_ID, self::KEY_DEPARTMENTS, '');
        return $value === '' ? [] : explode(',', $value);
    }

    /**
     * Department names (lowercase letters and digits: they become the start of hostnames), as a
     * list or one per line. Duplicates and empty lines are dropped; an empty list removes them.
     *
     * @param list<string>|string $departments
     */
    public function setDepartments(array|string $departments): void {
        if (is_string($departments)) {
            $departments = preg_split('/[\s,]+/', $departments) ?: [];
        }
        $clean = [];
        foreach ($departments as $department) {
            $department = strtolower(trim((string)$department));
            if ($department === '') {
                continue;
            }
            if (!preg_match(self::DEPARTMENT_RE, $department)) {
                throw new InvalidArgumentException("Department \"$department\": lowercase letters and digits only (it becomes the start of the computer name, before the '-')");
            }
            $clean[$department] = true;
        }
        if ($clean === []) {
            $this->appConfig->deleteKey(Application::APP_ID, self::KEY_DEPARTMENTS);
        } else {
            $this->appConfig->setValueString(Application::APP_ID, self::KEY_DEPARTMENTS, implode(',', array_keys($clean)));
        }
    }
}
