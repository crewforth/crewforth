package com.demo;

@RestController
@RequestMapping("/api")
public class AccountController {
  @Value("${app.name}")
  String name;
  @Value("${app.missing}")
  String missing;

  @GetMapping("/accounts/{id}")
  public String get() { return ""; }
}
