# frozen_string_literal: true

module AnonymousPost
  module UsernameSuggester
    RUSSIAN_TRANSLIT = {
      'А'=>'A','а'=>'a','Б'=>'B','б'=>'b','В'=>'V','в'=>'v',
      'Г'=>'G','г'=>'g','Д'=>'D','д'=>'d','Е'=>'E','е'=>'e',
      'Ё'=>'Yo','ё'=>'yo','Ж'=>'Zh','ж'=>'zh','З'=>'Z','з'=>'z',
      'И'=>'I','и'=>'i','Й'=>'Y','й'=>'y','К'=>'K','к'=>'k',
      'Л'=>'L','л'=>'l','М'=>'M','м'=>'m','Н'=>'N','н'=>'n',
      'О'=>'O','о'=>'o','П'=>'P','п'=>'p','Р'=>'R','р'=>'r',
      'С'=>'S','с'=>'s','Т'=>'T','т'=>'t','У'=>'U','у'=>'u',
      'Ф'=>'F','ф'=>'f','Х'=>'Kh','х'=>'kh','Ц'=>'Ts','ц'=>'ts',
      'Ч'=>'Ch','ч'=>'ch','Ш'=>'Sh','ш'=>'sh','Щ'=>'Sch','щ'=>'sch',
      'Ъ'=>'','ъ'=>'','Ы'=>'Y','ы'=>'y','Ь'=>'','ь'=>'',
      'Э'=>'E','э'=>'e','Ю'=>'Yu','ю'=>'yu','Я'=>'Ya','я'=>'ya'
    }.freeze

    module SuggesterPatch
      def suggest(name, *args)
        transliterated = name.to_s.gsub(
          /[#{AnonymousPost::UsernameSuggester::RUSSIAN_TRANSLIT.keys.join}]/,
          AnonymousPost::UsernameSuggester::RUSSIAN_TRANSLIT
        )
        super(transliterated, *args)
      end
    end

    def self.apply!(plugin)
      UserNameSuggester.singleton_class.prepend(SuggesterPatch)
    end
  end
end
