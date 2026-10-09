<?php

declare(strict_types=1);

namespace OCA\NextDesk\Settings;

use OCA\NextDesk\AppInfo\Application;
use OCP\IL10N;
use OCP\IURLGenerator;
use OCP\Settings\IIconSection;

/** Administration settings → NextDesk computers (its own entry in the sidebar). */
class ComputersSection implements IIconSection {
    public function __construct(
        private IL10N $l,
        private IURLGenerator $url,
    ) {
    }

    public function getID(): string {
        return 'nextdesk-computers';
    }

    public function getName(): string {
        return $this->l->t('NextDesk computers');
    }

    public function getPriority(): int {
        return 60;
    }

    public function getIcon(): string {
        return $this->url->imagePath(Application::APP_ID, 'computers.svg');
    }
}
