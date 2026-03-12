# TODO — Decouple Firewall Policy from Interfaces

## Problem
Firewall rules are currently generated **using interface names**.  
Policy in the model is defined using **tenants and services**, not interfaces.

This couples security policy to topology details and makes it fragile.

## Required Change
Write firewall policy using **tenant → tenant relations**, not interfaces.

Interfaces must then be **tagged with the tenant they belong to**, and that tenant policy is applied to them.

In short:

1. Define policy using tenants.
2. Map interfaces to tenants using solver data.
3. Apply the tenant policy to those interfaces.

Policy must **never be derived from interface names**.
