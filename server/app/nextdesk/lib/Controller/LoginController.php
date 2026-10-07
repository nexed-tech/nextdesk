<?php

declare(strict_types=1);

namespace OCA\NextDesk\Controller;

use OCA\NextDesk\Service\LoginTokenService;
use OCP\AppFramework\Controller;
use OCP\AppFramework\Http\Attribute\BruteForceProtection;
use OCP\AppFramework\Http\Attribute\NoCSRFRequired;
use OCP\AppFramework\Http\Attribute\PublicPage;
use OCP\AppFramework\Http\Attribute\UseSession;
use OCP\AppFramework\Http\RedirectResponse;
use OCP\Files\IRootFolder;
use OCP\IRequest;
use OCP\IURLGenerator;
use OCP\IUserManager;
use OCP\IUserSession;
use Psr\Log\LoggerInterface;

/**
 * Logs a device's browser in with a one-time token from ApiController::sessionToken.
 */
class LoginController extends Controller {
    public function __construct(
        string $appName,
        IRequest $request,
        private IUserManager $userManager,
        private IUserSession $userSession,
        private LoginTokenService $tokens,
        private IURLGenerator $urlGenerator,
        private LoggerInterface $logger,
        private IRootFolder $rootFolder,
    ) {
        parent::__construct($appName, $request);
    }

    #[PublicPage]
    #[NoCSRFRequired]
    #[UseSession]
    #[BruteForceProtection(action: 'nextdesk_login')]
    public function login(string $user = '', string $token = '', string $redirect = ''): RedirectResponse {
        $target = $this->safeRedirect($redirect);
        $account = $user !== '' ? $this->userManager->get($user) : null;

        if ($account === null || !$account->isEnabled() || $token === '' || !$this->tokens->consume($account, $token)) {
            // Fall back to the normal login, which brings the user to the same page afterwards.
            $response = new RedirectResponse($this->urlGenerator->linkToRoute('core.login.showLoginForm', ['redirect_url' => $this->safePath($redirect)]));
            $response->throttle(['user' => $user]);
            return $response;
        }

        $current = $this->userSession->getUser();
        if ($current === null || $current->getUID() !== $account->getUID()) {
            // Same steps apps like user_oidc take to log a user in after an external check.
            // These are methods of OC\User\Session, the IUserSession implementation.
            /** @var \OC\User\Session $session */
            $session = $this->userSession;
            $session->setUser($account);
            $session->completeLogin($account, ['loginName' => $account->getUID(), 'password' => '']);
            $session->createSessionToken($this->request, $account->getUID(), $account->getUID());
            $session->createRememberMeToken($account);
            // A user who has only used app passwords (devices) has never had a browser login,
            // so Nextcloud never set up their files; make sure they're there.
            try {
                $this->rootFolder->getUserFolder($account->getUID());
            } catch (\Throwable $e) {
                $this->logger->warning('NextDesk could not set up the files of {uid}', ['uid' => $account->getUID(), 'exception' => $e]);
            }
            $this->logger->info('NextDesk device logged in the browser of {uid}', ['uid' => $account->getUID()]);
        }

        return new RedirectResponse($target);
    }

    /** Only paths on this server, so the login URL can't send anyone elsewhere ('' if not). */
    private function safePath(string $redirect): string {
        if ($redirect !== '' && str_starts_with($redirect, '/') && !str_starts_with($redirect, '//') && !str_contains($redirect, '\\')) {
            return $redirect;
        }
        return '';
    }

    private function safeRedirect(string $redirect): string {
        $path = $this->safePath($redirect);
        return $path !== '' ? $this->urlGenerator->getAbsoluteURL($path) : $this->urlGenerator->linkToDefaultPageUrl();
    }
}
