<?php

declare(strict_types=1);

namespace OCA\NextDesk\Controller;

use InvalidArgumentException;
use OCA\NextDesk\Service\DevicePolicyService;
use OCA\NextDesk\Service\PolicyService;
use OCA\NextDesk\Service\RecoveryKeyService;
use OCP\AppFramework\Http\DataResponse;
use OCP\AppFramework\OCS\OCSBadRequestException;
use OCP\AppFramework\OCS\OCSNotFoundException;
use OCP\AppFramework\OCSController;
use OCP\IRequest;
use OCP\IUserSession;

/**
 * Administration (admins only): the settings page, `occ nextdesk:*` and management tools such
 * as Lintune.
 *
 * GET  /ocs/v2.php/apps/nextdesk/api/v1/admin/policy
 * PUT  /ocs/v2.php/apps/nextdesk/api/v1/admin/policy  {scope: global|group|user, id, policy: {...} | null}
 *
 * Device policy URL (one for all of this server's NextDesk machines):
 * GET  .../admin/device-policy
 * PUT  .../admin/device-policy  {url: "https://..." | ""}
 *
 * Disk recovery keys of devices (escrow):
 * GET    .../admin/recovery-keys            the devices, without keys
 * GET    .../admin/recovery-keys/{device}   machine id or hostname: with the key (logged)
 * DELETE .../admin/recovery-keys/{device}   machine id
 */
class AdminApiController extends OCSController {
    public function __construct(
        string $appName,
        IRequest $request,
        private PolicyService $policy,
        private RecoveryKeyService $recoveryKeys,
        private IUserSession $userSession,
        private DevicePolicyService $devicePolicy,
    ) {
        parent::__construct($appName, $request);
    }

    public function get(): DataResponse {
        return new DataResponse($this->state());
    }

    public function set(string $scope, string $id = '', ?array $policy = null): DataResponse {
        try {
            $this->policy->set($scope, $id, $policy);
        } catch (InvalidArgumentException $e) {
            throw new OCSBadRequestException($e->getMessage());
        }
        return new DataResponse($this->state());
    }

    public function getDevicePolicy(): DataResponse {
        return new DataResponse(['url' => $this->devicePolicy->getUrl()]);
    }

    public function setDevicePolicy(string $url = ''): DataResponse {
        try {
            $this->devicePolicy->setUrl($url);
        } catch (InvalidArgumentException $e) {
            throw new OCSBadRequestException($e->getMessage());
        }
        return new DataResponse(['url' => $this->devicePolicy->getUrl()]);
    }

    public function recoveryKeys(): DataResponse {
        return new DataResponse($this->recoveryKeys->list());
    }

    public function recoveryKey(string $device): DataResponse {
        $devices = $this->recoveryKeys->reveal($device, $this->userSession->getUser()?->getUID() ?? '?');
        if ($devices === []) {
            throw new OCSNotFoundException('No recovery key for this device');
        }
        return new DataResponse($devices);
    }

    public function deleteRecoveryKey(string $device): DataResponse {
        if (!$this->recoveryKeys->delete($device)) {
            throw new OCSNotFoundException('No recovery key for this device');
        }
        return new DataResponse(['deleted' => true]);
    }

    private function state(): array {
        return [
            'keys' => PolicyService::KEYS,
            'defaults' => $this->policy->defaults(),
            'global' => (object)$this->policy->getGlobal(),
            'groups' => (object)$this->policy->getGroups(),
            'users' => (object)$this->policy->getUsers(),
        ];
    }
}
