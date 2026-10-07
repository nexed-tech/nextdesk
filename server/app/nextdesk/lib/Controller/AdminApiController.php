<?php

declare(strict_types=1);

namespace OCA\NextDesk\Controller;

use InvalidArgumentException;
use OCA\NextDesk\Service\PolicyService;
use OCP\AppFramework\Http\DataResponse;
use OCP\AppFramework\OCS\OCSBadRequestException;
use OCP\AppFramework\OCSController;
use OCP\IRequest;

/**
 * Policy administration (admins only): the settings page, `occ nextdesk:policy` and
 * management tools such as Lintune.
 *
 * GET  /ocs/v2.php/apps/nextdesk/api/v1/admin/policy
 * PUT  /ocs/v2.php/apps/nextdesk/api/v1/admin/policy  {scope: global|group|user, id, policy: {...} | null}
 */
class AdminApiController extends OCSController {
    public function __construct(
        string $appName,
        IRequest $request,
        private PolicyService $policy,
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
