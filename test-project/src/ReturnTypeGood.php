<?php
namespace Test;

class ReturnTypeGood
{
    public function getInt(): int
    {
        return 42;
    }

    public function getString(): string
    {
        return "hello";
    }

    public function getBool(): bool
    {
        return true;
    }

    public function doVoid(): void
    {
        $x = 1;
    }

    public function conditional(bool $flag): int
    {
        if ($flag) {
            return 1;
        } else {
            return 2;
        }
    }

    public function earlyReturn(int $x): int
    {
        if ($x < 0) {
            return -1;
        }
        return $x;
    }

    public function nullable(): ?int
    {
        return null;
    }
}
