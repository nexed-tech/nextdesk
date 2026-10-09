<?php

declare(strict_types=1);

namespace OCA\NextDesk\Controller;

use InvalidArgumentException;
use OCA\NextDesk\Service\DevicePolicyService;
use OCA\NextDesk\Service\LoginTokenService;
use OCA\NextDesk\Service\PolicyService;
use OCA\NextDesk\Service\ComputerService;
use OCP\AppFramework\Http;
use OCP\AppFramework\Http\Attribute\BruteForceProtection;
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
        private ComputerService $computers,
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
     * The device policy for this server's NextDesk machines: {url, per_hostname, departments}
     * (public: machines and the installer ask before anyone signs in; the policy files are signed).
     */
    #[PublicPage]
    #[NoCSRFRequired]
    public function devicePolicy(): DataResponse {
        $policy = $this->devicePolicy->get();
        $policy['url'] = $policy['url'] ?: null;
        return new DataResponse($policy);
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
            $this->computers->storeRecoveryKey($machine_id, $hostname, $disk_uuid, $this->user()->getUID(), $key);
        } catch (InvalidArgumentException $e) {
            throw new OCSBadRequestException($e->getMessage());
        }
        return new DataResponse(['stored' => true]);
    }

    /**
     * A device reports with a signed-in user's app password (NextDesk computers page): registers
     * it and records the user. Answers with a device token ({token}) when the computer has none yet
     * or asks for one (new_token), for its own reports with nobody signed in (contact).
     *
     * @param array{name?: string, serial?: int, source?: string, applied_at?: int} $policy
     */
    #[NoAdminRequired]
    public function checkIn(string $machine_id, string $hostname = '', array $policy = [], string $version = '',
        int $installed_at = 0, bool $new_token = false): DataResponse {
        if (!$this->session->exists('app_password')) {
            throw new OCSForbiddenException('Only available with an app password');
        }
        try {
            $token = $this->computers->checkIn($machine_id, $hostname, $this->user()->getUID(), $policy, $version,
                $installed_at, $new_token);
        } catch (InvalidArgumentException $e) {
            throw new OCSBadRequestException($e->getMessage());
        }
        return new DataResponse($token === null ? ['ok' => true] : ['ok' => true, 'token' => $token]);
    }

    /**
     * The machine reports itself with its device token (from check-in), nobody signed in: last
     * contact, and the policy in force and the version when given. A wrong token or an unknown
     * machine: 403, and the address is throttled (brute force protection).
     *
     * @param array{name?: string, serial?: int, source?: string, applied_at?: int} $policy
     */
    #[PublicPage]
    #[NoCSRFRequired]
    #[BruteForceProtection(action: 'nextdesk_contact')]
    public function contact(string $machine_id, string $token, array $policy = [], string $version = '',
        int $installed_at = 0): DataResponse {
        if (!$this->computers->contact($machine_id, $token, $policy, $version, $installed_at)) {
            $response = new DataResponse(['ok' => false], Http::STATUS_FORBIDDEN);
            $response->throttle(['machine_id' => substr($machine_id, 0, 32)]);
            return $response;
        }
        return new DataResponse(['ok' => true]);
    }

    private function user(): IUser {
        $user = $this->userSession->getUser();
        if ($user === null) {
            throw new OCSForbiddenException();
        }
        return $user;
    }
}
