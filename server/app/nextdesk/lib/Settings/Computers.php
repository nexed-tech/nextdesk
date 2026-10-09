<?php

declare(strict_types=1);

namespace OCA\NextDesk\Settings;

use OCA\NextDesk\AppInfo\Application;
use OCP\AppFramework\Http\TemplateResponse;
use OCP\IL10N;
use OCP\Settings\IDelegatedSettings;
use OCP\Util;

/**
 * NextDesk computers (its own section): the computers that reported in, their policy and
 * version, and their disk recovery keys. Delegable (Administration settings → Administration
 * privileges), so a helpdesk group can unlock a disk without being an administrator.
 */
class Computers implements IDelegatedSettings {
    public function __construct(
        private IL10N $l,
    ) {
    }

    public function getForm(): TemplateResponse {
        Util::addScript(Application::APP_ID, 'computers');
        return new TemplateResponse(Application::APP_ID, 'computers');
    }

    public function getSection(): string {
        return 'nextdesk-computers';
    }

    public function getPriority(): int {
        return 10;
    }

    public function getName(): ?string {
        return $this->l->t('NextDesk computers and disk recovery keys');
    }

    public function getAuthorizedAppConfig(): array {
        return [];
    }
}
