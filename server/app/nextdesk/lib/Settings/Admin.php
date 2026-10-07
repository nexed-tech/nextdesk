<?php

declare(strict_types=1);

namespace OCA\NextDesk\Settings;

use OCA\NextDesk\AppInfo\Application;
use OCP\AppFramework\Http\TemplateResponse;
use OCP\Settings\ISettings;
use OCP\Util;

/** NextDesk policy, under Administration settings → Security. */
class Admin implements ISettings {
    public function getForm(): TemplateResponse {
        Util::addScript(Application::APP_ID, 'admin');
        return new TemplateResponse(Application::APP_ID, 'admin');
    }

    public function getSection(): string {
        return 'security';
    }

    public function getPriority(): int {
        return 90;
    }
}
