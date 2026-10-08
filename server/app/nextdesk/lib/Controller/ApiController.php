<?php

declare(strict_types=1);

namespace OCA\NextDesk\Controller;

use InvalidArgumentException;
use OCA\NextDesk\Service\DevicePolicyService;
use OCA\NextDesk\Service\LoginTokenService;
use OCA\NextDesk\Service\PolicyService;
use OCA\NextDesk\Service\RecoveryKeyService;
use OCP\AppFramework\Http\Attribute\NoAdminRequired;
use OCP\AppFramework\Http\Attribute\NoCSRFRequired;
use OCP\AppFramework\Http\Attribute\PublicPage;
use OCP\AppFramework\Http\DataResponse;
use OCP\AppFramework\OCS\OCSBadRequestException;
use OCP\AppFramework\OCS\OCSForbiddenException;
use OCP\AppFramework\OCSController;
use OCP\IRequest;
use OCP\ISession;
use OCP\IURLGenerator;
use OCP\IUser;
use OCP\IUserSession;

/**
 * API for NextDesk devices. They authenticate with their app password (from Login Flow v2).
 */
class ApiController extends OCSController {
    public function __construct(
        string $appName,
        IRequest $request,
        private IUserSession $userSession,
        private ISession $session,
        private PolicyService $policy,
        private LoginTokenService $tokens,
        private IURLGenerator $urlGenerator,
        private RecoveryKeyService $recoveryKeys,
        private DevicePolicyService $devicePolicy,
    ) {
        parent::__construct($appName, $request);
    }

    /**
     * The policy that applies to the signed-in user, and who that is.
     */
    #[NoAdminRequired]
    public function policy(): DataResponse {
        $user = $this->user();
        return new DataResponse([
            'user' => [
                'id' => $user->getUID(),
                'displayname' => $user->getDisplayName(),
                'email' => $user->getEMailAddress(),
            ],
            'policy' => $this->policy->effective($user),
        ]);
    }

    /**
     * A one-time URL that logs the browser in as this user.
     *
     * Only for app passwords (devices): a browser session can't mint one, so a script in a
     * web page can't use it to create sessions elsewhere.
     */
    #[NoAdminRequired]
    public function sessionToken(string $redirect = ''): DataResponse {
        if (!$this->session->exists('app_password')) {
            throw new OCSForbiddenException('Only available with an app password');
        }
        $user = $this->user();
        $params = ['user' => $user->getUID(), 'token' => $this->tokens->create($user)];
        if ($redirect !== '') {
            $params['redirect'] = $redirect;
        }
        return new DataResponse([
            'url' => $this->urlGenerator->linkToRouteAbsolute('nextdesk.login.login', $params),
            'expires_in' => LoginTokenService::TTL,
        ]);
    }

    /**
     * The device policy URL for this server's NextDesk machines (public: machines and the
     * installer ask before anyone signs in; the policy itself is signed).
     */
    #[PublicPage]
    #[NoCSRFRequired]
    public function devicePolicy(): DataResponse {
        return new DataResponse(['url' => $this->devicePolicy->getUrl() ?: null]);
    }

    /**
     * Escrow of this device's disk recovery key (one per machine id; replaces an older key).
     * Only for app passwords (devices). The key can't be read back with this API.
     */
    #[NoAdminRequired]
    public function recoveryKey(string $machine_id, string $key, string $hostname = '', string $disk_uuid = ''): DataResponse {
        if (!$this->session->exists('app_password')) {
            throw new OCSForbiddenException('Only available with an app password');
        }
        try {
            $this->recoveryKeys->store($machine_id, $hostname, $disk_uuid, $this->user()->getUID(), $key);
        } catch (InvalidArgumentException $e) {
            throw new OCSBadRequestException($e->getMessage());
        }
        return new DataResponse(['stored' => true]);
    }

    private function user(): IUser {
        $user = $this->userSession->getUser();
        if ($user === null) {
            throw new OCSForbiddenException();
        }
        return $user;
    }
}
