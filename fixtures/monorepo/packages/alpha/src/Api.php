<?php

declare(strict_types=1);

namespace Alpha;

/**
 * Alpha's public API, consumed across the package boundary by Beta.
 */
class Api
{
    public static function getData(): string
    {
        return 'data';
    }
}
