<?php

declare(strict_types=1);

namespace Beta;

use Alpha\Api;

/**
 * Beta calls into Alpha across the package boundary (a static call, which
 * resolves at confidence 1.0).
 */
class Consumer
{
    public function run(): string
    {
        return Api::getData();
    }
}
