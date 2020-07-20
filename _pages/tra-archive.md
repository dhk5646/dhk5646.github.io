---
title: "여행"
permalink: /tra/
layout: category
author_profile: true
tra_tag: ["jeju"]
---
{% include group-by-array collection=site.posts field="tags" %}

{% for traTag in page.tra_tag %}
{% for tag in group_names %}
{% if traTag == tag %}
<h2 id="{{ tag | slugify }}" class="archive__subtitle">{{ tag }}</h2>
{% assign posts = group_items[forloop.index0] %}
{% for post in posts %}
{% assign category = post.categories %}
{% if category[0] == 'tra' %}

{% include archive-single.html %}
{% endif %}
{% endfor %}
{% endif %}
{% endfor %}
{% endfor %}