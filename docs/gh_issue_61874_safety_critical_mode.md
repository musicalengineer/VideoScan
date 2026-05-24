# GitHub Issue #61874 — Safety Critical Mode

- **URL:** https://github.com/anthropics/claude-code/issues/61874
- **Repo:** anthropics/claude-code
- **Author:** Rick Breen (musicalengineer)
- **Created:** 2026-05-23T19:08:48Z
- **State:** OPEN
- **Labels:** enhancement, area:core
- **Priority:** Medium - Would be very helpful
- **Category:** Configuration and settings

## Title

[FEATURE] Safety Critical Mode

## Problem Statement

Feature Request: **Safety-Critical Mode** (not to be confused with security) as used in automotive, medical, aerospace, etc. so Claude prompts for top-notch SW Dev process, possibly including TDD, insisting on Best Practices, unit tests, stress tests, rigorous reviews, code metrics, ala safety critical dev. I have 40+ years experience, much of it in safety critical, but also audio/video and more. I've been using Claude to develop a complex application to sort through terabytes of home videos, identify family, repair broken/orphaned AV files. The app is entirely written by Claude on macos Swift, using many frameworks and heavily multi-threaded - it can quickly get out of control if vibe-coding, so I am training Claude with directives for Best Practices, code quality, metrics, CI, etc. This FEATURE request is for Claude to have a **safety-critical** mode where Claude uses the latest and greatest best practices, as if developing for medical. I'd even go further and say it should be **ON** and users can switch it off. Or users get prompted occasionally with "**Do you want to use safety critical/best practices?**". I love using Claude but it sure can learn a lot from a veteran safety critical developer. I've written md files to direct safety-critical mode but Claude is VERY geared to generate code as fast as possible to please the user, then things get out of control fast. Any vibe coder or budding developer would learn so much and maybe better code would result, we can hope. Please read this to make Claude better, I know you all have the best intentions.

Thank you and good luck,
Rick B.
Retired safety-critical/audio-video developer, astronomer, musician.

## Proposed Solution

Safety-critical Development Process mode switch so Claude prompts user to write a test, use a code analyzer, and otherwise follow best practices as if developing say, a medical device. Many may not use it, but many may learn so much. Better code, a better world.

## Alternative Solutions

MD files with strong safety-critical process can go a long way, but I found myself fighting Claude to do the right thing, not Claude's fault it wanted to generate code quickly and bypass all my directives. Maybe a safety critical md file written better would have the same effect. I kinda think Claude gets so focused on producing code it kinda forgets some of the safety critical directives, but the feature request

## Use Case Example

User gets prompted "Use safety critical dev process" for this coding task.
User can opt out.
Possibly different levels or modes, 1,2,3 or FDA 62304, NASA-STD-XYZ, DOT, etc.
Users who are brave enough and patient enough to use such a mode would be guided through the best practices for their purpose and/or target.

## Additional Context

Feel free to look at all my transcripts to see how the app was developed and I had to teach Claude all about best practices. In some ways it went well, in others, fast coding and bypassing process, seemed to be Claude's trend which I completely understand.
