<?php

declare(strict_types=1);

namespace Test\Notify;

/**
 * A second implementor of NotifierInterface. Its mere presence makes the
 * interface ambiguous, so Phase A single-implementor binding no longer applies.
 * Only the explicit services.yaml binding (Phase B) can decide which concrete
 * an interface-typed call resolves to.
 */
class SmsNotifier implements NotifierInterface
{
    public function send(string $message): void
    {
        // Pretend to send an SMS.
    }
}
