class Match < ApplicationRecord
  require 'elo'

  belongs_to :home_team, class_name: 'Team'
  belongs_to :away_team, class_name: 'Team'
  belongs_to :division, optional: true
  belongs_to :court, optional: true
  belongs_to :tournament_round, optional: true # TODO: if exists, ensure unique tournament_order
  has_many :games, -> { order(:number) }, inverse_of: :match, dependent: :nullify

  # TODO: Fix callback to work on updates
  after_create :calculate_elo

  # TODO: home team and away team must be different
  # TODO: if league, validate both teams in same division

  def teams
    [away_team, home_team]
  end

  delegate :season, to: :division

  def winner
    return nil if home_score == away_score

    home_score > away_score ? home_team : away_team
  end

  def calculate_elo
    return unless counts_toward_elo

    throw 'score required for match' unless home_score && away_score

    # TODO: if date < latest match, calculate all of those ELOs as well, as this busts cache

    home_elo = ::Elo::Player.new(rating: home_team.elo_cache, games_played: home_team.match_count)
    away_elo = ::Elo::Player.new(rating: away_team.elo_cache, games_played: away_team.match_count)

    if home_score > away_score
      home_elo.wins_from(away_elo)
    elsif away_score > home_score
      away_elo.wins_from(home_elo)
    end

    # apply the Match's Multiplier to scale the change in elo
    #  expects self::Multiplier to never be nil
    home_elo_change = multiplier * (home_elo.rating - home_team.elo_cache)
    away_elo_change = multiplier * (away_elo.rating - away_team.elo_cache)

    # Save ELO to Match, applying the change in elo
    self.home_old_elo = home_team.elo_cache
    self.away_old_elo = away_team.elo_cache
    self.home_new_elo = home_team.elo_cache + home_elo_change
    self.away_new_elo = away_team.elo_cache + away_elo_change
    save

    # Save ELO to Teams
    unless home_score == away_score
      home_team.update(previous_elo: home_team.elo_cache)
      away_team.update(previous_elo: away_team.elo_cache)
      home_team.update(elo_cache: home_team.elo_cache + home_elo_change)
      away_team.update(elo_cache: away_team.elo_cache + away_elo_change)
    end
  end

  def formatted_date
    return '' unless time

    time.in_time_zone('America/Chicago').strftime("%b #{time.in_time_zone('America/Chicago').day.ordinalize} %Y")
  end

  def formatted_datetime
    return '' unless time

    time.in_time_zone('America/Chicago').strftime("%b #{time.in_time_zone('America/Chicago').day.ordinalize} %Y, %-l:%M%P")
  end

  def formatted_time
    return '' unless time

    time.in_time_zone('America/Chicago').strftime('%-l:%M%P')
  end

  def team_result(id)
    return nil unless [home_team_id, away_team_id].include?(id)

    return 'tied' if home_score == away_score

    return 'won' if home_team_id == id && home_score > away_score
    return 'won' if away_team_id == id && away_score > home_score

    return 'lost' if home_team_id == id && home_score < away_score
    return 'lost' if away_team_id == id && away_score < home_score
  end

  def team_info(id)
    if home_team_id == id
      {
        opponent: away_team,
        result: team_result(id),
        old_elo: home_old_elo,
        new_elo: home_new_elo
      }
    elsif away_team_id == id
      {
        opponent: home_team,
        result: team_result(id),
        old_elo: away_old_elo,
        new_elo: away_new_elo
      }
    end
  end

  def tied?
    home_score == away_score
  end

  def matchup_summary
    away_record = away_team.record
    home_record = home_team.record

    [
      [full_location, away_team.name, home_team.name],
      ['ELO', away_team.elo_cache, home_team.elo_cache],
      ['Record', "#{away_record[:wins]}-#{away_record[:losses]}\t", "#{home_record[:wins]}-#{home_record[:losses]}\t"]
    ]
  end

  def export_summary
    [
      id,
      time.in_time_zone('America/Chicago').iso8601,
      full_location,
      division ? division.name : '',
      comment,
      home_team.name,
      away_team.name,
      winner ? winner.name : '',
      home_score,
      away_score,
      home_old_elo,
      home_new_elo,
      away_old_elo,
      away_new_elo
    ]
  end

  def full_location
    return "#{court.full_name} - #{location}" if court && location
    return court.full_name if court
    return location if location

    ''
  end

  def bracket_meta
    {
      id: id,
      away_team_id: away_team_id,
      home_team_id: home_team_id,
      winning_team_id: winner ? winner.id : nil,
      away_team_name: away_team.display_name,
      home_team_name: home_team.display_name,
      winning_team_name: winner ? winner.display_name : nil,
      time: time # UTC
    }
  end

  def create_palms_doubles_games(first_yellow_team, first_black_team)
    throw 'first_yellow_team must be a Team from this Match' unless [away_team, home_team].include?(first_yellow_team)
    throw 'first_black_team must be a Team from this Match' unless [away_team, home_team].include?(first_black_team)
    throw 'first_yellow_team must not be same as first_black_team' if first_yellow_team == first_black_team

    Game.create(
      match: self,
      number: 1,
      yellow_team: first_yellow_team,
      black_team: first_black_team,
      game_type: 'palms_doubles',
      max_frames: 8,
      allow_ties: false,
      frames: []
    )

    Game.create(
      match: self,
      number: 2,
      yellow_team: first_black_team,
      black_team: first_yellow_team,
      game_type: 'palms_doubles',
      max_frames: 8,
      allow_ties: false,
      frames: []
    )

    Game.create(
      match: self,
      number: 3,
      yellow_team: first_yellow_team,
      black_team: first_black_team,
      game_type: 'palms_doubles',
      max_frames: 4,
      change_colors_every_frames: 2,
      allow_ties: false,
      frames: []
    )
  end

  def ae_data
    {
      starting_yellow_team: games.first.yellow_team.name,
      starting_black_team: games.first.black_team.name,
      yellow_match_score: series_score_progression[0],
      black_match_score: series_score_progression[1],
      frames: games.map(&:frames)
    }
  end

  def self.recalculate_all_elo
    # Disable logging
    old_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger.level = 1

    Team.reset_all_elo

    Match.all.order(:time, :id).each(&:calculate_elo)

    # Set logging back to old level
    ActiveRecord::Base.logger = old_logger
  end

  private

  def series_score_progression
    yellow = [0]
    black = [0]

    games.each_with_index do |g, i|
      # when i even (0, 2 / Game 1 & 3), use team series score of your own color
      # when i odd (1 / Game 2), use team series score of your other color
      yellow.push(g.series_score[i % 2])
      black.push(g.series_score[(i + 1) % 2]) # swap that for black scores by increasing i by 1
    end

    [yellow, black]
  end
end
