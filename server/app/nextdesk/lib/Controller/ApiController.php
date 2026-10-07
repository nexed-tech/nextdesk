<?php

declare(strict_types=1);

namespace OCA\NextDesk\Controller;

use OCA\NextDesk\Service\LoginTokenService;
use OCA\NextDesk\Service\PolicyService;
use OCP\AppFramework\Http\Attribute\NoAdminRequired;
use OCP\AppFramework\Http\DataResponse;
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

    private function user(): IUser {
        $user = $this->userSession->getUser();
        if ($user === null) {
            throw new OCSForbiddenException();
        }
        return $user;
    }
}
