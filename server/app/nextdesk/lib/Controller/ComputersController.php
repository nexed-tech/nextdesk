<?php

declare(strict_types=1);

namespace OCA\NextDesk\Controller;

use OCA\NextDesk\Service\ComputerService;
use OCA\NextDesk\Settings\Computers;
use OCP\AppFramework\Http\Attribute\AuthorizedAdminSetting;
use OCP\AppFramework\Http\DataResponse;
use OCP\AppFramework\OCS\OCSForbiddenException;
use OCP\AppFramework\OCS\OCSNotFoundException;
use OCP\AppFramework\OCSController;
use OCP\IGroupManager;
use OCP\IRequest;
use OCP\IUserSession;

/**
 * The NextDesk computers page (Administration settings → NextDesk computers): administrators,
 * and groups the section is delegated to (Administration settings → Administration privileges),
 * e.g. a helpdesk.
 *
 * GET    /ocs/v2.php/apps/nextdesk/api/v1/computers?search=&limit=50&offset=0
 * GET    .../computers/{machineId}/recovery-key   the key (logged: who, which computer)
 * DELETE .../computers/{machineId}                 administrators only
 */
class ComputersController extends OCSController {
    public function __construct(
        string $appName,
        IRequest $request,
        private ComputerService $computers,
        private IUserSession $userSession,
        private IGroupManager $groupManager,
    ) {
        parent::__construct($appName, $request);
    }

    #[AuthorizedAdminSetting(settings: Computers::class)]
    public function index(string $search = '', int $limit = 50, int $offset = 0): DataResponse {
        $page = $this->computers->search($search, $limit, $offset);
        $page['can_delete'] = $this->isAdmin();
        return new DataResponse($page);
    }

    #[AuthorizedAdminSetting(settings: Computers::class)]
    public function recoveryKey(string $machineId): DataResponse {
        if (!preg_match('/^[0-9a-f]{32}$/', $machineId)) {
            throw new OCSNotFoundException('No such computer');
        }
        $computers = $this->computers->revealKey($machineId, $this->userId());
        if ($computers === []) {
            throw new OCSNotFoundException('No recovery key for this computer');
        }
        return new DataResponse($computers[0]);
    }

    /** Only administrators: a delegated group can look keys up, not remove computers. */
    #[AuthorizedAdminSetting(settings: Computers::class)]
    public function destroy(string $machineId): DataResponse {
        if (!$this->isAdmin()) {
            throw new OCSForbiddenException('Only administrators can delete computers');
        }
        if (!$this->computers->delete($machineId, $this->userId())) {
            throw new OCSNotFoundException('No such computer');
        }
        return new DataResponse(['deleted' => true]);
    }

    private function userId(): string {
        return $this->userSession->getUser()?->getUID() ?? '?';
    }

    private function isAdmin(): bool {
        return $this->groupManager->isAdmin($this->userId());
    }
}
