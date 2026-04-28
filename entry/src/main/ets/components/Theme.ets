/**
 * Central colour/metric tokens. Keeping them in one class means a design
 * tweak is one edit, not twenty.
 */
export class Theme {
  public static readonly BG: string = '#F5F7FB';
  public static readonly CARD: string = '#FFFFFF';
  public static readonly BORDER: string = '#E5E9F0';
  public static readonly TEXT: string = '#1E293B';
  public static readonly TEXT_MUTED: string = '#64748B';
  public static readonly TEXT_PRIMARY: string = '#64748B';
  public static readonly TEXT_INVERT: string = '#FFFFFF';
  public static readonly HEADER: string = '#0F172A';
  public static readonly HEADER_ACCENT: string = '#1E293B';

  public static readonly PRIMARY: string = '#2563EB';
  public static readonly PRIMARY_SOFT: string = '#DBEAFE';
  public static readonly SUCCESS: string = '#10B981';
  public static readonly DANGER: string = '#EF4444';
  public static readonly WARN: string = '#F59E0B';
  public static readonly NEUTRAL: string = '#475569';

  public static readonly LOG_BG: string = '#0F172A';
  public static readonly LOG_TEXT: string = '#E2E8F0';
  public static readonly LOG_MUTED: string = '#94A3B8';

  public static readonly RADIUS_MD: number = 10;
  public static readonly RADIUS_LG: number = 14;
}

/**
 * Visual intent mapped to a background color. Buttons, badges, and chips all
 * consume this so "primary" looks the same everywhere.
 */
export enum ButtonTone {
  Primary = 'primary',
  Neutral = 'neutral',
  Success = 'success',
  Danger = 'danger',
  Warn = 'warn'
}

export class ToneResolver {
  public static bg(tone: ButtonTone): string {
    if (tone === ButtonTone.Primary) return Theme.PRIMARY;
    if (tone === ButtonTone.Success) return Theme.SUCCESS;
    if (tone === ButtonTone.Danger) return Theme.DANGER;
    if (tone === ButtonTone.Warn) return Theme.WARN;
    return Theme.NEUTRAL;
  }
}
